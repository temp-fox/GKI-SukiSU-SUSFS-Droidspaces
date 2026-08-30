#!/usr/bin/env bash
# 编译内核，产出 out/arch/arm64/boot/Image。
#
# 走传统 make 而非 bazel/kleaf —— 厂商开源包不含 build/ 和 prebuilts/，
# 没有 bazel 构建环境。工具链由外部提供。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_env WORKSPACE
KERNEL_DIR="${KERNEL_DIR:-$WORKSPACE/common}"
export KERNEL_DIR
export DEFCONFIG="${DEFCONFIG:-$KERNEL_DIR/arch/arm64/configs/gki_defconfig}"

cd "$KERNEL_DIR"

# =============================================================================
# 工具链
# =============================================================================

section "工具链"

export PATH="$WORKSPACE/clang/bin:$WORKSPACE/build-tools/bin:$WORKSPACE/build-tools/path/linux-x86:/usr/lib/ccache:$PATH"

require_cmd clang   "工具链未正确解压，检查 $WORKSPACE/clang/bin"
require_cmd ld.lld  "工具链缺少 ld.lld"

log "Clang:  $(clang --version | head -1)"
log "LLD:    $(ld.lld --version | head -1)"
if command -v pahole >/dev/null 2>&1; then
    log "pahole: $(pahole --version 2>&1 | head -1)"
else
    warn "pahole 未安装 —— 若开启了 CONFIG_DEBUG_INFO_BTF 会编译失败"
fi

# =============================================================================
# ccache
#
# ⚠️ 用 CCACHE_COMPILERCHECK=content，不用 none。
#    前身项目用 none + LD_PRELOAD 伪造 mtime，命中率确实高，
#    但换工具链或补丁改了源码时有拿到陈旧目标文件的风险 ——
#    表现是「明明改了代码，产物却没变化」，极难排查。
#    content 会读编译器二进制内容做 hash，牺牲一点首次命中率换正确性。
# =============================================================================

section "ccache"

if command -v ccache >/dev/null 2>&1; then
    export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
    export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-5G}"
    export CCACHE_COMPILERCHECK=content
    export CCACHE_COMPRESS=true
    export CCACHE_BASEDIR="$WORKSPACE"
    export CCACHE_NOHASHDIR=true

    # sloppiness：放宽这几项，它们在内核构建里会造成大量无谓的 miss
    #   file_macro       __FILE__ 展开路径不同不算差异
    #   time_macros      __DATE__/__TIME__ 不算差异
    #   include_file_mtime / ctime  头文件时间戳不算差异（内容一样就行）
    export CCACHE_SLOPPINESS="file_macro,time_macros,include_file_mtime,include_file_ctime"

    mkdir -p "$CCACHE_DIR"
    ccache -M "$CCACHE_MAXSIZE" >/dev/null
    ccache -o compression=true

    log "缓存目录: $CCACHE_DIR （上限 $CCACHE_MAXSIZE）"
    ccache -s 2>/dev/null | head -8 | sed 's/^/    /' || true

    CC_CMD="ccache clang"
else
    warn "ccache 不可用，本次为冷编译"
    CC_CMD="clang"
fi

# =============================================================================
# 构建参数
# =============================================================================

MAKE_ARGS=(
    -j"$(nproc --all)"
    LLVM=1
    LLVM_IAS=1
    ARCH=arm64
    CROSS_COMPILE=aarch64-linux-gnu-
    CC="$CC_CMD"
    LD=ld.lld
    HOSTLD=ld.lld
    O=out
    KCFLAGS=-O2
    # GKI 源码里有些警告在新版 clang 下会升级成错误，
    # 而我们无权改厂商代码，只能降级
    KCFLAGS=-Wno-error
)

# SukiSU 的版本号通过 make 变量覆盖，而不是 sed 改它的 Kbuild。
# 改 Kbuild 的问题是：上游一改格式我们的 sed 就静默失效，
# 版本号悄悄退回兜底值，直到刷机才发现管理器不认。
if [ -n "${KSU_VERSION:-}" ]; then
    MAKE_ARGS+=(
        KSU_VERSION="$KSU_VERSION"
        KSU_VERSION_FULL="${KSU_VERSION_FULL:-}"
    )
    log "覆盖 KSU_VERSION=$KSU_VERSION"
fi

# config_data 伪装规则。由 setup-optional.sh 写入 GITHUB_ENV，
# 这里透传给 kernel/Makefile 里被补丁加进去的 config_spoof。
# 未启用该特性时变量为空，补丁里那段整个跳过。
if [ -n "${KERNEL_CONFIG_SPOOF:-}" ]; then
    MAKE_ARGS+=( KERNEL_CONFIG_SPOOF="$KERNEL_CONFIG_SPOOF" )
    log "config_data 伪装: $KERNEL_CONFIG_SPOOF"
fi

# =============================================================================
# 生成 .config
# =============================================================================

section "生成 .config"

make "${MAKE_ARGS[@]}" gki_defconfig || die "gki_defconfig 生成失败"
require_file "$KERNEL_DIR/out/.config" "生成的 .config"

# =============================================================================
# 编译前自检 —— 这一步不能跳
# =============================================================================

OUT_CONFIG="$KERNEL_DIR/out/.config" bash "$SCRIPT_DIR/verify-config.sh"

# =============================================================================
# 编译
# =============================================================================

section "编译内核"

START_TS=$(date +%s)
BUILD_LOG="$WORKSPACE/build-kernel.log"
rm -f "$BUILD_LOG"

# GitHub 对公开仓库的完整 job log 下载可能需要权限。把 make Image 的
# 输出同步保存成失败诊断产物，后续不用依赖 Actions 私有日志接口。
set +e
make "${MAKE_ARGS[@]}" Image 2>&1 | tee "$BUILD_LOG"
MAKE_RC=${PIPESTATUS[0]}
set -e

if [ "$MAKE_RC" -ne 0 ]; then
    die "内核编译失败。

     已保存编译日志: $BUILD_LOG

     排查建议：
     1. 看 build-kernel.log 里的第一条 error（不是最后一条）——后面的多半是连锁反应
     2. 若报找不到 vendor/ 下的文件 → prepare-vendor-stubs.sh 没覆盖到，
        把缺的文件补进那个脚本
     3. 若报某个 SUSFS 宏未定义 → SUSFS 补丁的头部 hunk 被跳过了，
        看 setup-susfs.sh 的上下文适配是否覆盖当前 sublevel"
fi

ELAPSED=$(( $(date +%s) - START_TS ))
ok "编译完成，耗时 $((ELAPSED / 60)) 分 $((ELAPSED % 60)) 秒"

# =============================================================================
# 产物校验
# =============================================================================

section "产物校验"

IMAGE="$KERNEL_DIR/out/arch/arm64/boot/Image"
require_file "$IMAGE" "内核镜像"

IMAGE_SIZE=$(stat -c%s "$IMAGE")
IMAGE_MB=$(( IMAGE_SIZE / 1024 / 1024 ))
log "Image 体积: ${IMAGE_MB} MB （${IMAGE_SIZE} 字节）"

# GKI 的 arm64 Image 本身是自解压的压缩镜像，实测 30-40 MB
# （本机型 34 MB）。明显偏小说明编译出来的东西不对，
# 比如某个 config 意外关掉了一大块功能。
[ "$IMAGE_MB" -ge 20 ] || die "Image 只有 ${IMAGE_MB} MB，明显异常。
     GKI 内核正常应在 30 MB 以上。检查 .config 是否被意外精简。"

# 从 Image 里读版本串 —— 这是验证版本伪装是否生效的最直接方式
VERSION_STR="$(strings "$IMAGE" | grep -m1 'Linux version' || true)"
if [ -n "$VERSION_STR" ]; then
    ok "版本串: $VERSION_STR"
    put_env KERNEL_VERSION_STRING "$VERSION_STR"

    # 版本伪装校验：设备配置声明了后缀，产物里就应该有
    if [ -n "${FINAL_LOCALVERSION:-}" ] \
       && ! grep -qF "$FINAL_LOCALVERSION" <<< "$VERSION_STR"; then
        warn "版本串里没有预期的后缀 '$FINAL_LOCALVERSION'"
        warn "  版本伪装可能没生效，刷入后 uname -r 会与原厂不一致"
    fi
else
    warn "无法从 Image 中读出版本串"
fi

if command -v ccache >/dev/null 2>&1; then
    section "ccache 统计"
    ccache -s 2>/dev/null | sed 's/^/  /' || true
fi

df -h "$WORKSPACE" | sed 's/^/  /'

ok "内核构建成功: $IMAGE"
put_env KERNEL_IMAGE "$IMAGE"
