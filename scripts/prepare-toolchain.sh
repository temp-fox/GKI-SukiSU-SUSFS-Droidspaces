#!/usr/bin/env bash
# 下载并解压工具链（clang + build-tools）。
#
# 厂商开源包不含 prebuilts/，必须外部提供工具链。
# 由 workflow 用 actions/cache 按 TOOLCHAIN_KEY 缓存，通常只在首次构建时跑。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_env WORKSPACE
mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

section "工具链"

# 默认工具链：LLVM-Clang20。
# 用较新的 clang 编译 6.1 没有问题，且前身项目已实机验证。
DEFAULT_TC_BASE="https://github.com/cctv18/oneplus_sm8650_toolchain/releases/download/LLVM-Clang20-r547379"
TC_URL="${TOOLCHAIN_URL:-$DEFAULT_TC_BASE/clang-r547379.zip}"
BT_URL="${BUILD_TOOLS_URL:-$DEFAULT_TC_BASE/build-tools.zip}"

fetch_and_unzip() {
    local url="$1" dest="$2" label="$3"

    if [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
        skip "$label 已存在（缓存命中）"
        return 0
    fi

    log "下载 $label"
    log "  $url"
    local tmp="/tmp/$(basename "$dest").zip"

    if command -v aria2c >/dev/null 2>&1; then
        aria2c -s16 -x16 -k1M --console-log-level=warn --summary-interval=0 \
               -d /tmp -o "$(basename "$tmp")" "$url" \
            || die "下载 $label 失败"
    else
        curl -fSL --retry 3 -o "$tmp" "$url" || die "下载 $label 失败"
    fi

    mkdir -p "$dest"
    unzip -q "$tmp" -d "$dest" || die "解压 $label 失败"
    rm -f "$tmp"
    ok "$label 就绪"
}

fetch_and_unzip "$TC_URL" "$WORKSPACE/clang"       "Clang 工具链"
fetch_and_unzip "$BT_URL" "$WORKSPACE/build-tools" "构建工具"

# 有些 zip 会多套一层目录，把 bin/ 提上来
for d in "$WORKSPACE/clang" "$WORKSPACE/build-tools"; do
    if [ ! -d "$d/bin" ]; then
        inner="$(find "$d" -maxdepth 2 -type d -name bin | head -1)"
        if [ -n "$inner" ]; then
            log "展平目录结构: ${inner%/bin} → $d"
            mv "${inner%/bin}"/* "$d/" 2>/dev/null || true
        fi
    fi
done

# =============================================================================
# boot.img 打包工具（可选）
#
# 来自 android.googlesource.com。若网络不通就跳过 —— 只影响 boot.img，
# AnyKernel3 刷机包不受影响。
# =============================================================================

if is_true "${OUTPUT_BOOT_IMG:-true}"; then
    section "boot.img 打包工具"

    AOSP_BRANCH=main-kernel-build-2024

    if [ -d "$WORKSPACE/mkbootimg" ]; then
        skip "mkbootimg 已存在"
    elif git clone --depth=1 -b "$AOSP_BRANCH" \
           https://android.googlesource.com/platform/system/tools/mkbootimg \
           "$WORKSPACE/mkbootimg" 2>/dev/null; then
        ok "mkbootimg 就绪"
    else
        warn "无法获取 mkbootimg，将跳过 boot.img 产出（不影响 AnyKernel3 包）"
    fi

    if [ -d "$WORKSPACE/kernel-build-tools" ]; then
        skip "kernel-build-tools 已存在"
    elif git clone --depth=1 -b "$AOSP_BRANCH" \
           https://android.googlesource.com/kernel/prebuilts/build-tools \
           "$WORKSPACE/kernel-build-tools" 2>/dev/null; then
        ok "kernel-build-tools（含 avbtool）就绪"
    else
        warn "无法获取 avbtool，boot.img 将不带 AVB 签名"
    fi
fi

section "工具链验证"

export PATH="$WORKSPACE/clang/bin:$WORKSPACE/build-tools/bin:$PATH"
require_cmd clang  "clang 不在 $WORKSPACE/clang/bin 中，检查工具链 zip 的结构"
require_cmd ld.lld "ld.lld 缺失"

ok "$(clang --version | head -1)"
ok "$(ld.lld --version | head -1)"
