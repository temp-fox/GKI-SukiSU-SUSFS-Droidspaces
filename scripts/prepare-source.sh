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
        log "解析 ${SOURCE_REPO}@${SOURCE_REF} 的 commit sha..."
        SOURCE_SHA="$(curl -fsSL \
            ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/${SOURCE_REPO}/commits/${SOURCE_REF}" \
            | grep -m1 '"sha"' | cut -d'"' -f4)"

        [ -n "$SOURCE_SHA" ] || die "无法解析 ${SOURCE_REPO}@${SOURCE_REF} 的 sha"
        ok "源码 commit: $SOURCE_SHA"

        ZIP_URL="https://github.com/${SOURCE_REPO}/archive/${SOURCE_SHA}.zip"
        log "下载: $ZIP_URL"

        if command -v aria2c >/dev/null 2>&1; then
            aria2c -s16 -x16 -k1M --console-log-level=warn \
                   --summary-interval=0 -o src.zip "$ZIP_URL"
        else
            curl -fSL --retry 3 -o src.zip "$ZIP_URL"
        fi

        log "解压中（大仓库需要几分钟）..."
        unzip -q src.zip
        rm -f src.zip

        # ���动探测解压出来的顶层目录，不依赖硬编码目录名。
        # 厂商仓库改名或换 ref 时都不会因此崩掉。
        if [ -n "${SOURCE_UNZIP_DIR:-}" ]; then
            EXTRACTED="$SOURCE_UNZIP_DIR"
        else
            EXTRACTED="$(find . -maxdepth 1 -mindepth 1 -type d \
                         ! -name common ! -name vendor ! -name 'KernelSU*' \
                         -printf '%f\n' | head -1)"
        fi
        [ -n "$EXTRACTED" ] && [ -d "$EXTRACTED" ] \
            || die "解���后未找到源码目录（探测结果：'$EXTRACTED'）"

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
