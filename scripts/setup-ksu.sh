#!/usr/bin/env bash
# 集成 SukiSU-Ultra。
#
# 【为什么默认用 builtin 分支】
# SukiSU-Ultra 的 main 分支内核侧对 SUSFS 是零支持 —— 没有 Kconfig 选项、
# 没有 susfs_init() 调用、reboot 命令通道也只认自己的 magic，不认 SUSFS 的。
# 前身项目在 main 上手搓了一个 600 多行的适配层，其中 reboot 命令分发器
# 只有函数体、从未被调用，导致 `ksud susfs version` 永远返回 "unsupport"，
# 管理器设置页每次重组都发一次注定超时的 root shell 请求 → 界面卡死。
#
# builtin 分支自带完整 SUSFS 支持，命令通道由上游原生提供。
#
# 【KSU_VERSION 是最容易踩的坑】
# 管理器有三条独立的版本校验路径，任一不过就报「版本不匹配」：
#   1. KSU_VERSION < 32513
#   2. KSU_VERSION_FULL 语义版本 < v4.0.0
#   3. 内核 UAPI 版本 != 管理器 UAPI 版本
# 而 KSU_VERSION 由 commit 计数推导，浅克隆或删掉 .git 都会让计数失败，
# 落到兜底值 13000 —— 远小于 32513，刷完机才会发现。
# 所以本脚本在构建期就把这些断言跑完。
#
# 输出到 $GITHUB_ENV：
#   KSU_SHA / KSU_REF_RESOLVED / KSU_VERSION / KSU_VERSION_FULL / KSU_TAG

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_env WORKSPACE
KERNEL_DIR="${KERNEL_DIR:-$WORKSPACE/common}"
KSU_REF="${KSU_REF:-builtin}"
ENABLE_SUSFS="${ENABLE_SUSFS:-true}"

cd "$WORKSPACE"

section "集成 SukiSU-Ultra （ref: $KSU_REF）"

# -----------------------------------------------------------------------------
# 1. 拉取
#
# 用官方 setup.sh 而不是自己 clone + 建符号链接。
# setup.sh 做三件事：clone 到 KernelSU/、建 drivers/kernelsu 相对符号链接、
# 改 drivers/Makefile 与 drivers/Kconfig。上游改了挂载方式我们自动跟随。
# -----------------------------------------------------------------------------

SETUP_URL="https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh"

if [ -d KernelSU ]; then
    skip "KernelSU/ 已存在，跳过 setup.sh"
else
    log "下载并执行官方 setup.sh"
    # 先下载到本地再执行，而不是 curl | bash 直接管道 ——
    # 这样失败时能看到脚本内容，也能在日志里留档。
    curl -fsSL "$SETUP_URL" -o /tmp/ksu-setup.sh \
        || die "无法下载 SukiSU setup.sh"
    [ -s /tmp/ksu-setup.sh ] || die "下载到的 setup.sh 是空文件"

    bash /tmp/ksu-setup.sh "$KSU_REF" \
        || die "SukiSU setup.sh 执行失败（ref=$KSU_REF）"
fi

require_dir "$WORKSPACE/KernelSU" "SukiSU 源码"
require_dir "$KERNEL_DIR/drivers/kernelsu" "setup.sh 应建立的驱动挂载点"

# -----------------------------------------------------------------------------
# 2. 修复 git 历史
#
# ⚠️ 绝不 rm -rf KernelSU/.git —— Makefile 靠它算 commit 数。
#    浅克隆同理：rev-list --count 只会数到很小的值。
# -----------------------------------------------------------------------------

cd "$WORKSPACE/KernelSU"

[ -d .git ] || die "KernelSU/.git 不存在。
     SukiSU 的 Makefile 依赖 git commit 计数推导版本号，
     没有 .git 会落到兜底值 13000，管理器必然报版本不匹配。
     检查是否有步骤删掉了它。"

if [ -f .git/shallow ]; then
    log "检测到浅克隆，补全完整历史（否则 commit 计数会偏小）"
    git fetch --unshallow || git fetch --depth=1000000 || \
        warn "补全历史失败，commit 计数可能不准"
fi

# Makefile 里写死了 REPO_BRANCH := main，即使我们 checkout 到 builtin
# 也会去数 main 的 commit。确保本地有 main 这个 ref。
if ! git rev-parse --verify main >/dev/null 2>&1; then
    log "本地无 main ref，从 origin 拉取"
    git fetch origin main:main 2>/dev/null \
        || git fetch origin main:refs/remotes/origin/main 2>/dev/null \
        || warn "拉取 main ref 失败"
fi

KSU_SHA="$(git rev-parse HEAD)"
KSU_SHORT="$(git rev-parse --short=8 HEAD)"
KSU_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "$KSU_REF")"
KSU_DATE="$(git log -1 --date=format:'%Y-%m-%d %H:%M:%S' --format='%cd')"

ok "SukiSU: $KSU_SHORT @ $KSU_BRANCH （最后提交 $KSU_DATE）"

# -----------------------------------------------------------------------------
# 3. 校验所选 ref 确实含 SUSFS
#
# 这是「设置界面卡死」的根因防线。如果有人把 ksu_ref 改成 main 又开着
# SUSFS，会重蹈前身项目的覆辙 —— 而且要刷完机才发现。
# -----------------------------------------------------------------------------

if is_true "$ENABLE_SUSFS"; then
    section "校验 SukiSU 内核侧 SUSFS 支持"

    KCONFIG="$WORKSPACE/KernelSU/kernel/Kconfig"
    require_file "$KCONFIG" "SukiSU Kconfig"

    grep -qE '^[[:space:]]*config[[:space:]]+KSU_SUSFS[[:space:]]*$' "$KCONFIG" \
        || die "ksu_ref='$KSU_REF' 的内核侧没有 SUSFS 支持（Kconfig 里没有 KSU_SUSFS）。

     SukiSU-Ultra 的 main 分支内核侧对 SUSFS 是零支持。
     用它 + SUSFS 会导致 ksud 的 reboot 命令通道打不通，
     \`ksud susfs version\` 返回 unsupport，管理器设置界面卡死。

     请把 ksu_ref 改成 builtin（默认值），或关闭 enable_susfs。"

    # 光有 Kconfig 不够，还得确认 init 流程真的调用了 susfs_init()。
    # 前身项目的适配层就是「函数体存在但没人调用」这种失败。
    if grep -rqs "susfs_init" "$WORKSPACE/KernelSU/kernel/"; then
        ok "  Kconfig 有 KSU_SUSFS，且内核代码引用了 susfs_init"
    else
        die "Kconfig 声明了 KSU_SUSFS，但内核代码里找不到 susfs_init 调用。
     上游结构可能变了，需要人工确认集成方式。"
    fi

    # reboot 命令通道 —— SUSFS 靠 reboot(2) + 双 magic 与内核通信
    if grep -rqs "reboot" "$WORKSPACE/KernelSU/kernel/supercall/" 2>/dev/null; then
        ok "  supercall 存在 reboot 处理路径"
    else
        warn "  未在 supercall/ 找到 reboot 处理，SUSFS 命令通道可能不通"
        warn "    刷机后请务必验证：ksud susfs version 应返回 vX.Y.Z 而非 unsupport"
    fi
fi

# -----------------------------------------------------------------------------
# 4. 推导并校验 KSU_VERSION
#
# 计算公式（来自 SukiSU 的 kernel/Kbuild 或 kernel/Makefile）：
#   KSU_VERSION = VERSION_BASE + commit_count - VERSION_OFFSET
# 管理器侧用同一公式（manager/build.gradle.kts），这是官方的设计约定。
#
# 不硬编码 40000 / 2815 —— 从 Kbuild 里读，上游改了自动跟随。
# -----------------------------------------------------------------------------

section "推导 KSU_VERSION"

KBUILD=""
for candidate in kernel/Kbuild kernel/Makefile; do
    [ -f "$candidate" ] && { KBUILD="$candidate"; break; }
done
[ -n "$KBUILD" ] || die "找不到 SukiSU 的 kernel/Kbuild 或 kernel/Makefile"
log "版本定义文件: $KBUILD"

VERSION_BASE="$(grep -oP '^VERSION_BASE\s*:?=\s*\K[0-9]+'   "$KBUILD" | head -1 || true)"
VERSION_OFFSET="$(grep -oP '^VERSION_OFFSET\s*:?=\s*\K[0-9]+' "$KBUILD" | head -1 || true)"

[ -n "$VERSION_BASE" ]   || die "无法从 $KBUILD 解析 VERSION_BASE，上游格式可能变了"
[ -n "$VERSION_OFFSET" ] || die "无法从 $KBUILD 解析 VERSION_OFFSET，上游格式可能变了"
log "  VERSION_BASE=$VERSION_BASE  VERSION_OFFSET=$VERSION_OFFSET"

# Makefile 数的是 main 分支的 commit，我们也数 main 保持一致
COMMIT_COUNT=""
for ref in main HEAD; do
    if COMMIT_COUNT="$(git rev-list --count "$ref" 2>/dev/null)" && [ "$COMMIT_COUNT" -gt 100 ]; then
        log "  commit 计数基准: $ref = $COMMIT_COUNT"
        break
    fi
    COMMIT_COUNT=""
done
[ -n "$COMMIT_COUNT" ] || die "git commit 计数失败（main 和 HEAD 都取不到合理值）。
     这会让 KSU_VERSION 落到兜底值 13000，管理器报版本不匹配。"

if [ -n "${KSU_VERSION_OVERRIDE:-}" ]; then
    KSU_VERSION="$KSU_VERSION_OVERRIDE"
    warn "使用手工指定的 KSU_VERSION=$KSU_VERSION（覆盖推导值）"
else
    KSU_VERSION=$(( VERSION_BASE + COMMIT_COUNT - VERSION_OFFSET ))
    ok "推导: $VERSION_BASE + $COMMIT_COUNT - $VERSION_OFFSET = $KSU_VERSION"
fi

# 管理器的硬门槛。低于它刷完机就是「管理器版本 X 和驱动版本 Y 不匹配」。
MIN_KSU_VERSION=32513
[ "$KSU_VERSION" -ge "$MIN_KSU_VERSION" ] || die "KSU_VERSION=$KSU_VERSION 低于管理器最低要求 $MIN_KSU_VERSION。
     管理器会拒绝识别这个内核。
     通常是 commit 计数不对（浅克隆 / .git 缺失 / main ref 不可达）。
     实在需要手工指定，用 ksu_version_override 输入项。"

# 语义版本：管理器还会检查 KSU_VERSION_FULL 是否 >= v4.0.0
KSU_TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo '')"
if [ -n "$KSU_TAG" ]; then
    KSU_VERSION_FULL="${KSU_TAG}-${KSU_SHORT}@${KSU_BRANCH}"
    TAG_MAJOR="$(echo "${KSU_TAG#v}" | cut -d. -f1)"
    if [[ "$TAG_MAJOR" =~ ^[0-9]+$ ]] && [ "$TAG_MAJOR" -lt 4 ]; then
        warn "最近的 tag 是 $KSU_TAG（主版本 < 4），管理器可能拒绝识别"
    fi
else
    KSU_VERSION_FULL="v4.0.0-${KSU_SHORT}@${KSU_BRANCH}"
    warn "找不到 git tag，KSU_VERSION_FULL 用兜底值 $KSU_VERSION_FULL"
fi

ok "KSU_VERSION      = $KSU_VERSION"
ok "KSU_VERSION_FULL = $KSU_VERSION_FULL"

# -----------------------------------------------------------------------------
# 5. 导出
#
# 不改 Kbuild 硬写版本号 —— 那会让 Kbuild 与上游产生分歧，
# 上游改了格式我们的 sed 就静默失效。改为在 make 时用变量覆盖。
# -----------------------------------------------------------------------------

put_env KSU_SHA          "$KSU_SHA"
put_env KSU_SHORT        "$KSU_SHORT"
put_env KSU_REF_RESOLVED "$KSU_BRANCH"
put_env KSU_DATE         "$KSU_DATE"
put_env KSU_VERSION      "$KSU_VERSION"
put_env KSU_VERSION_FULL "$KSU_VERSION_FULL"
put_env KSU_TAG          "${KSU_TAG:-none}"

put_output ksu_version "$KSU_VERSION"
put_output ksu_sha     "$KSU_SHORT"

ok "SukiSU 集成完成"
