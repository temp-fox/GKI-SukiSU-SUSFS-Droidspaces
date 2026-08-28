#!/usr/bin/env bash
# 获取内核源码，产出 $WORKSPACE/common/
#
# 支持三种来源（由设备配置的 SOURCE_TYPE 决定）：
#   github-zip     GitHub zip 快照，按 commit sha 下载（避免 TOCTOU）
#   git            git clone --depth=1
#   repo-manifest  repo + AOSP manifest（Google ACK 官方方式）
#
# 输出到 $GITHUB_ENV：
#   SOURCE_SHA          实际使用的源码 commit（github-zip / git 模式）
#   ACTUAL_SUBLEVEL     从 Makefile 提取的真实 SUBLEVEL

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_env WORKSPACE SOURCE_TYPE
mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

section "获取内核源码"

if [ -d "$WORKSPACE/common" ] && [ -f "$WORKSPACE/common/Makefile" ]; then
    skip "common/ 已存在（缓存命中），跳过下载"
else
    case "$SOURCE_TYPE" in
    # -------------------------------------------------------------------------
    github-zip)
        require_env SOURCE_REPO SOURCE_REF
        require_cmd curl

        # 先把 ref 解析成确定的 sha，再按 sha 下载。
        #
        # ⚠️ 前身项目在这里有 TOCTOU：先 ls-remote 记录 sha 写进产物信息，
        #    再另起一条命令下载 refs/heads/master.zip。两步之间上游若推了
        #    新 commit，产物记录的 sha 和实际编译的源码就对不上了。
        #
        # ⚠️ 用 vnd.github.sha 媒体类型拿裸 sha，不要 `| grep -m1 '"sha"'`：
        #    commits API 的 JSON 带完整 files 数组（本机型约 380 KB），
        #    而 "sha" 在开头，grep -m1 命中即关管道 → curl 吃 SIGPIPE →
        #    exit 23 → 被本脚本开头的 pipefail 放大成硬失败。
        log "解析 ${SOURCE_REPO}@${SOURCE_REF} 的 commit sha..."
        SOURCE_SHA="$(curl -fsSL --retry 3 \
            ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} \
            -H "Accept: application/vnd.github.sha" \
            "https://api.github.com/repos/${SOURCE_REPO}/commits/${SOURCE_REF}")"

        # 必须是 40 位十六进制。只判非空不够 —— 限流或仓库不存在时
        # 返回的是 JSON 错误页，非空但完全不是 sha，会一路带到下载环节
        # 拼出一个 404 的 zip URL，错误信息指不到根因。
        [[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] \
            || die "解析 ${SOURCE_REPO}@${SOURCE_REF} 的 sha 失败。
     期望 40 位十六进制，实际返回：'${SOURCE_SHA:0:200}'
     常见原因：仓库名或 ref 写错、仓库是私有的、API 限流。"
        ok "源码 commit: $SOURCE_SHA"

        ZIP_URL="https://github.com/${SOURCE_REPO}/archive/${SOURCE_SHA}.zip"
        log "下载: $ZIP_URL"

        if command -v aria2c >/dev/null 2>&1; then
            aria2c -s16 -x16 -k1M --console-log-level=warn \
                   --summary-interval=0 -o src.zip "$ZIP_URL" \
                || die "aria2c 下载源码失败"
        else
            curl -fSL --retry 3 -o src.zip "$ZIP_URL" || die "curl 下载源码失败"
        fi

        # 下载完整性：GitHub 出错时会返回一个 HTML 错误页，
        # 文件名照样是 src.zip，只有几 KB。不验一下会一路错到解压。
        require_file src.zip "下载的源码 zip"
        ZIP_BYTES="$(stat -c%s src.zip)"
        log "zip 体积: $(( ZIP_BYTES / 1024 / 1024 )) MB"
        [ "$ZIP_BYTES" -gt 52428800 ] \
            || die "源码 zip 只有 $(( ZIP_BYTES / 1024 )) KB，明显异常（内核源码应在 200 MB 以上）。
     多半下到的是 GitHub 的错误页而不是 zip。前 200 字节：
$(head -c 200 src.zip | tr -d '\0' | sed 's/^/         /')"

        # zip 顶层目录名从 zip 自己的目录表里读，而不是解压后靠 find 猜。
        #
        # ⚠️ 原先用 `find . -maxdepth 1 -type d ... | head -1` 探测，有两个毛病：
        #    1. find 的输出顺序由文件系统决定，不保证是我们要的那个目录
        #    2. 探测发生在解压之后，一旦 unzip 部分失败就会把残留目录
        #       误认成源码根，mv 成 common/ 后直到校验 Makefile 才报错，
        #       错误信息完全指不到根因（首次 CI 就栽在这里）
        TOP_DIRS="$(unzip -Z1 src.zip 2>/dev/null \
                    | sed -n 's|^\([^/]*\)/.*|\1|p' | sort -u)"
        TOP_COUNT="$(printf '%s\n' "$TOP_DIRS" | grep -c . || true)"
        log "zip 顶层目录: $(printf '%s' "$TOP_DIRS" | tr '\n' ' ')"

        if [ -n "${SOURCE_UNZIP_DIR:-}" ]; then
            EXTRACTED="$SOURCE_UNZIP_DIR"
        elif [ "$TOP_COUNT" -eq 1 ]; then
            EXTRACTED="$TOP_DIRS"
        else
            die "zip 里有 ${TOP_COUNT} 个顶层目录，无法自动判断哪个是源码根：
$(printf '%s\n' "$TOP_DIRS" | sed 's/^/         /')
     请在 devices/${DEVICE_CODE:-<机型>}.env 里设置 SOURCE_UNZIP_DIR 明确指定。"
        fi

        log "解压中（大仓库需要几分钟）..."
        # -qq 而非 -q：静默解压会掩盖部分失败，-qq 保留错误但不刷屏。
        # -o 强制覆盖：文件已存在时 unzip 默认交互式提问，而 CI 里 stdin
        #    是空的 → 读到 EOF → 非零退出。缓存部分命中或重跑时会撞上。
        unzip -qq -o src.zip || die "解压 src.zip 失败"
        rm -f src.zip

        [ -d "$EXTRACTED" ] \
            || die "解压后没有预期的目录 '$EXTRACTED'。
     当前工作区内容：
$(ls -la | sed 's/^/         /')"

        # 在 mv 之前就确认这确实是内核源码根 —— 早失败一步，
        # 错误信息就能指到「zip 结构不符预期」而不是「Makefile 不存在」
        [ -f "$EXTRACTED/Makefile" ] && [ -d "$EXTRACTED/arch/arm64" ] \
            || die "'$EXTRACTED' 不像内核源码根（缺 Makefile 或 arch/arm64）。
     该目录内容：
$(ls -la "$EXTRACTED" | head -25 | sed 's/^/         /')
     若源码在子目录里，请在 devices/*.env 设置 SOURCE_UNZIP_DIR。"

        mv "$EXTRACTED" common
        put_env SOURCE_SHA "$SOURCE_SHA"
        ;;

    # -------------------------------------------------------------------------
    git)
        require_env SOURCE_REPO SOURCE_REF
        log "clone https://github.com/${SOURCE_REPO}.git @ ${SOURCE_REF}"
        git clone --depth=1 -b "$SOURCE_REF" \
            "https://github.com/${SOURCE_REPO}.git" common
        SOURCE_SHA="$(git -C common rev-parse HEAD)"
        put_env SOURCE_SHA "$SOURCE_SHA"
        ;;

    # -------------------------------------------------------------------------
    repo-manifest)
        require_env SOURCE_MANIFEST_BRANCH
        require_cmd repo "请先安装 repo 工具"

        log "repo init -b $SOURCE_MANIFEST_BRANCH"
        repo init --depth=1 -u https://android.googlesource.com/kernel/manifest \
             -b "$SOURCE_MANIFEST_BRANCH" --repo-rev=v2.16

        # 已弃用的分支在 manifest 里被移到 deprecated/ 下
        REMOTE_BRANCH="$(git ls-remote \
            https://android.googlesource.com/kernel/common \
            "${ANDROID_VERSION}-${KERNEL_VERSION}" || true)"
        if grep -q deprecated <<< "$REMOTE_BRANCH"; then
            warn "检测到已弃用分支，改用 deprecated/ 路径"
            sed -i "s|\"${SOURCE_MANIFEST_BRANCH#common-}\"|\"deprecated/${SOURCE_MANIFEST_BRANCH#common-}\"|g" \
                .repo/manifests/default.xml
        fi

        repo sync -c -j"$(nproc --all)" --no-tags --fail-fast
        put_env SOURCE_SHA "manifest:${SOURCE_MANIFEST_BRANCH}"
        ;;

    *)
        die "未知的 SOURCE_TYPE: $SOURCE_TYPE（应为 github-zip / git / repo-manifest）"
        ;;
    esac
fi

# -----------------------------------------------------------------------------
# 校验源码确实是预期的版本
# -----------------------------------------------------------------------------
section "校验源码版本"

require_file "$WORKSPACE/common/Makefile" "内核 Makefile"

MK_VERSION="$(awk -F'= *' '/^VERSION *=/{print $2; exit}'    "$WORKSPACE/common/Makefile" | tr -d ' ')"
MK_PATCHLEVEL="$(awk -F'= *' '/^PATCHLEVEL *=/{print $2; exit}' "$WORKSPACE/common/Makefile" | tr -d ' ')"
MK_SUBLEVEL="$(awk -F'= *' '/^SUBLEVEL *=/{print $2; exit}'   "$WORKSPACE/common/Makefile" | tr -d ' ')"

ACTUAL_KV="${MK_VERSION}.${MK_PATCHLEVEL}"
ok "源码版本: ${ACTUAL_KV}.${MK_SUBLEVEL}"

# 主次版本号必须匹配 —— 不匹配意味着 SUSFS 补丁分支选错了，
# 与其让 SUSFS 补丁打出一堆 .rej，不如在这里就说清楚。
if [ -n "${KERNEL_VERSION:-}" ] && [ "$ACTUAL_KV" != "$KERNEL_VERSION" ]; then
    die "内核版本不符：设备配置声明 $KERNEL_VERSION，源码实际是 $ACTUAL_KV
     请修正 devices/${DEVICE_CODE}.env 里的 KERNEL_VERSION"
fi

# SUBLEVEL 只警告不失败：厂商仓库同步上游 LTS 后会变，
# 而 SUSFS 补丁的上下文适配是按区间判断的，小幅漂移通常没问题。
if [ -n "${KERNEL_SUBLEVEL:-}" ] && [ "$MK_SUBLEVEL" != "$KERNEL_SUBLEVEL" ]; then
    warn "SUBLEVEL 漂移：配置声明 $KERNEL_SUBLEVEL，源码实际是 $MK_SUBLEVEL"
    warn "  后续按实际值 $MK_SUBLEVEL 处理。若 SUSFS 补丁失败，先看这里。"
fi
put_env ACTUAL_SUBLEVEL "$MK_SUBLEVEL"

# 展示源码性质，方便排查
if [ -f "$WORKSPACE/common/build.config.constants" ]; then
    log "build.config.constants:"
    sed 's/^/    /' "$WORKSPACE/common/build.config.constants"
fi

# -----------------------------------------------------------------------------
# 去掉 ABI 保护与 -dirty 后缀
# -----------------------------------------------------------------------------
section "解除 ABI 限制"

cd "$WORKSPACE/common"

# GKI 的受保护导出符号列表会拒绝我们新增的 EXPORT_SYMBOL
if compgen -G "android/abi_gki_protected_exports_*" >/dev/null; then
    rm -f android/abi_gki_protected_exports_*
    ok "已移除 abi_gki_protected_exports_*"
fi

# 源码树被我们改过，setlocalversion 会追加 -dirty，破坏版本串伪装
if [ -f scripts/setlocalversion ]; then
    sed -i 's/ -dirty//g' scripts/setlocalversion
    # 兜底：在最后一行前插入一次显式清洗，防止上游改了拼接方式
    if ! grep -q "s/-dirty//g" scripts/setlocalversion; then
        sed -i '$i res=$(echo "$res" | sed '"'"'s/-dirty//g'"'"')' scripts/setlocalversion
    fi
    ok "已清除 setlocalversion 的 -dirty 后缀"
fi

# defconfig 严格检查会因为我们追加的配置项而失败
if [ -f build.config.gki ]; then
    sed -i 's/check_defconfig//' build.config.gki
    ok "已禁用 build.config.gki 的 check_defconfig"
fi

ok "源码准备完成: $WORKSPACE/common"
