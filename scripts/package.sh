#!/usr/bin/env bash
# 输出产物：AnyKernel3 刷机包 + 内核 Image + boot.img + 构建信息。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_env WORKSPACE
KERNEL_DIR="${KERNEL_DIR:-$WORKSPACE/common}"
IMAGE="${KERNEL_IMAGE:-$KERNEL_DIR/out/arch/arm64/boot/Image}"
OUT_DIR="${OUT_DIR:-$WORKSPACE/artifacts}"

require_file "$IMAGE" "内核镜像"
mkdir -p "$OUT_DIR"

# =============================================================================
# 构造产物名
#
# 名字要能一眼看出「这个包是什么配置」—— 手机里放着七八个刷机包时，
# 靠文件名分辨比翻构建日志快得多。
# =============================================================================

section "构造产物名"

TAGS=""
is_true "${ENABLE_DROIDSPACES:-false}" && TAGS="${TAGS}_ds"
is_true "${ENABLE_KPM:-false}"         && TAGS="${TAGS}_kpm"
is_true "${ENABLE_ZRAM:-false}"        && TAGS="${TAGS}_zram"
is_true "${ENABLE_NETWORK_EXT:-false}" && TAGS="${TAGS}_net"
is_true "${ENABLE_REKERNEL:-false}"    && TAGS="${TAGS}_rek"
is_true "${ENABLE_BBR:-false}"         && TAGS="${TAGS}_bbr"
is_true "${ENABLE_NTSYNC:-false}"      && TAGS="${TAGS}_ntsync"
is_true "${ENABLE_BBG:-false}"         && TAGS="${TAGS}_bbg"

BASE_NAME="${DEVICE_CODE:-kernel}_${KERNEL_VERSION:-}.${ACTUAL_SUBLEVEL:-${KERNEL_SUBLEVEL:-}}"
[ -n "${KSU_VERSION:-}" ]   && BASE_NAME="${BASE_NAME}_SukiSU-${KSU_VERSION}"
[ -n "${SUSFS_VERSION:-}" ] && BASE_NAME="${BASE_NAME}_SUSFS-${SUSFS_VERSION}"
BASE_NAME="${BASE_NAME}${TAGS}"

ok "产物基名: $BASE_NAME"
put_env ARTIFACT_NAME "$BASE_NAME"
put_output artifact_name "$BASE_NAME"

# =============================================================================
# 构建信息
#
# 写成独立文件，同时放进 AnyKernel3 目录内，和 Image / boot.img 分开上传。
# =============================================================================

section "生成构建信息"

INFO="$OUT_DIR/build-info.txt"
cat > "$INFO" <<EOF
================================================================
 GKI-SukiSU-SUSFS-Droidspaces 构建信息
================================================================

设备
  型号            ${DEVICE_NAME:-未知} (${DEVICE_CODE:-?})
  主板            ${DEVICE_BOARD:-未知}
  对应固件        ${DEVICE_FIRMWARE:-未知}

内核
  版本            ${KERNEL_VERSION:-?}.${ACTUAL_SUBLEVEL:-?}-${ANDROID_VERSION:-?}
  KMI generation  ${KMI_GENERATION:-未知}
  版本串          ${KERNEL_VERSION_STRING:-未知}
  源码            ${SOURCE_REPO:-?} @ ${SOURCE_SHA:-?}

Root 方案
  SukiSU-Ultra    ${KSU_REF_RESOLVED:-?} @ ${KSU_SHORT:-?}
  编译模式        ${KSU_BUILD_MODE:-未知}${KSU_CONFIG_VALUE:+ ($KSU_CONFIG_VALUE)}
  版本号          ${KSU_VERSION:-未启用}
  完整版本        ${KSU_VERSION_FULL:-未启用}
  上游提交日期    ${KSU_DATE:-未知}
  Manager 包名    ${KSU_MANAGER_PACKAGE:-未设置}
  Manager 签名    size=${KSU_EXPECTED_SIZE:-未设置} hash=${KSU_EXPECTED_HASH:-未设置}

SUSFS
  启用            $(is_true "${ENABLE_SUSFS:-false}" && echo "是" || echo "否")
  版本            ${SUSFS_VERSION:-未启用}
  补丁提交        ${SUSFS_SHA:-未启用}
  上游提交日期    ${SUSFS_DATE:-未知}

Droidspaces
  启用            $(is_true "${ENABLE_DROIDSPACES:-false}" && echo "是" || echo "否")
  kABI 槽位       ${DROIDSPACES_KABI_SLOTS:-未启用}
  oplus midas 修复 $(is_true "${NEEDS_OPLUS_MIDAS_FIX:-false}" && echo "已应用" || echo "未应用")

可选特性
  KPM             $(is_true "${ENABLE_KPM:-false}"         && echo "开" || echo "关")
  网络功能扩展    $(is_true "${ENABLE_NETWORK_EXT:-false}" && echo "开" || echo "关")
  zram            $(is_true "${ENABLE_ZRAM:-false}"        && echo "开" || echo "关")
  Re-Kernel       $(is_true "${ENABLE_REKERNEL:-false}"    && echo "开" || echo "关")
  BBR             $(is_true "${ENABLE_BBR:-false}"         && echo "开" || echo "关")
  NTsync          $(is_true "${ENABLE_NTSYNC:-false}"      && echo "开" || echo "关")
  基带保护 BBG    $(is_true "${ENABLE_BBG:-false}"         && echo "开" || echo "关")

构建
  时间            $(date -u '+%Y-%m-%d %H:%M:%S UTC')
  构建器提交      ${GITHUB_SHA:-本地构建}
  工作流          ${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}

================================================================
 刷入前请阅读
================================================================

1. 务必先备份当前 boot 分区
2. SukiSU 管理器请用与本内核同期的版本，否则可能报版本不匹配
   本内核的 KSU_VERSION 是 ${KSU_VERSION:-未启用}
3. 刷入后的验证步骤见 docs/troubleshooting.md
EOF

cat "$INFO"

# =============================================================================
# AnyKernel3
# =============================================================================

section "准备 AnyKernel3"

AK3_SRC="$WORKSPACE/AnyKernel3"
AK3_OUT="$OUT_DIR/AnyKernel3_${BASE_NAME}"
if [ ! -d "$AK3_SRC" ]; then
    log "克隆 AnyKernel3"
    git clone --depth=1 -b gki-2.0 \
        https://github.com/WildKernels/AnyKernel3.git "$AK3_SRC" \
        || die "无法克隆 AnyKernel3"
    rm -rf "$AK3_SRC/.git"
fi

rm -rf "$AK3_OUT"
mkdir -p "$AK3_OUT"
cp -a "$AK3_SRC"/. "$AK3_OUT"/
cp "$IMAGE" "$AK3_OUT/Image"
cp "$INFO"  "$AK3_OUT/build-info.txt"

require_file "$AK3_OUT/anykernel.sh" "AnyKernel3 脚本"
require_file "$AK3_OUT/Image"        "AnyKernel3 内核 Image"

# 不在这里再生成 AnyKernel3_*.zip。actions/upload-artifact 下载时本来就会
# 产出一个 zip；如果先 zip 再上传，用户拿到的是「artifact zip 里套刷机包 zip」
# 的两层结构。直接上传目录内容，下载到的 artifact zip 本身就是可刷 AK3 包。
ok "AnyKernel3 目录: $(basename "$AK3_OUT")"

# =============================================================================
# 导出内核 Image
# =============================================================================

section "导出内核 Image"

IMAGE_OUT="$OUT_DIR/${BASE_NAME}_Image"
cp "$IMAGE" "$IMAGE_OUT"
require_file "$IMAGE_OUT" "内核 Image"
ok "Image: $(basename "$IMAGE_OUT") （$(du -h "$IMAGE_OUT" | cut -f1)）"

# =============================================================================
# boot.img
#
# android13 及以上的 GKI boot 分区不含 ramdisk，所以只需要 kernel。
# =============================================================================

if is_true "${OUTPUT_BOOT_IMG:-true}"; then
    section "构建 boot.img"

    MKBOOTIMG="${MKBOOTIMG:-$WORKSPACE/mkbootimg/mkbootimg.py}"
    AVBTOOL="${AVBTOOL:-$WORKSPACE/kernel-build-tools/linux-x86/bin/avbtool}"

    if [ ! -f "$MKBOOTIMG" ]; then
        warn "找不到 mkbootimg，跳过 boot.img（仍会输出内核 Image）"
    else
        BOOT_DIR="$WORKSPACE/bootimg"
        mkdir -p "$BOOT_DIR"
        cd "$BOOT_DIR"
        cp "$IMAGE" ./Image

        # AVB 签名密钥。用测试密钥即可 —— bootloader 已解锁的设备
        # 不校验签名，这里签名只是为了让镜像格式完整。
        SIGN_KEY="${BOOT_SIGN_KEY_PATH:-$BOOT_DIR/testkey_rsa2048.pem}"
        if [ ! -f "$SIGN_KEY" ]; then
            openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
                > "$SIGN_KEY" 2>/dev/null
        fi

        # boot 分区大小。avbtool add_hash_footer 会把镜像补零填充到
        # 这个尺寸，所以三个 boot*.img 产出后体积完全一致（各 64 MB），
        # gz / lz4 的压缩优势在文件体积上看不出来 —— 这是 AVB 的正常
        # 行为，不是打包出错。刷入时 bootloader 只读实际内容，不受填充影响。
        #
        # ⚠️ 不同机型的 boot 分区大小不同。填小了刷不进去，填大了产物虚胖。
        #    默认 64 MB 是 android13+ GKI 的常见值，机型不同就在
        #    devices/<机型>.env 里设 BOOT_PARTITION_SIZE 覆盖。
        #    查本机真实值：adb shell 下
        #      blockdev --getsize64 /dev/block/by-name/boot_a
        BOOT_PARTITION_SIZE="${BOOT_PARTITION_SIZE:-$(( 64 * 1024 * 1024 ))}"
        log "boot 分区大小: $(( BOOT_PARTITION_SIZE / 1024 / 1024 )) MB（镜像会被 AVB 填充到该尺寸）"

        make_boot() {
            local kernel="$1" suffix="$2"
            [ -f "$kernel" ] || return 0

            python3 "$MKBOOTIMG" --header_version 4 \
                --kernel "$kernel" --output "boot${suffix}.img" \
                || { warn "boot${suffix}.img 生成失败"; return 0; }

            if [ -x "$AVBTOOL" ]; then
                "$AVBTOOL" add_hash_footer \
                    --partition_name boot \
                    --partition_size "$BOOT_PARTITION_SIZE" \
                    --image "boot${suffix}.img" \
                    --algorithm SHA256_RSA2048 \
                    --key "$SIGN_KEY" \
                    || warn "boot${suffix}.img 签名失败（未解锁设备可能无法刷入）"
            fi

            cp "boot${suffix}.img" "$OUT_DIR/${BASE_NAME}_boot${suffix}.img"
            ok "  boot${suffix}.img"
        }

        make_boot ./Image     ""
    fi
fi

# =============================================================================
# 收集 .rej（若有）
# =============================================================================

REJ_COUNT=$(find "$KERNEL_DIR" -name '*.rej' -type f 2>/dev/null | wc -l)
if [ "$REJ_COUNT" -gt 0 ]; then
    section "收集补丁冲突"
    REJ_DIR="$OUT_DIR/patch-rejects"
    mkdir -p "$REJ_DIR"

    while IFS= read -r rej; do
        rel="${rej#"$KERNEL_DIR"/}"
        mkdir -p "$REJ_DIR/$(dirname "$rel")"
        cp "$rej" "$REJ_DIR/$rel"
        # 连同被打补丁的原文件一起收集，方便对照
        [ -f "${rej%.rej}" ] && cp "${rej%.rej}" "$REJ_DIR/${rel%.rej}"
        echo "$rel" >> "$REJ_DIR/index.txt"
    done < <(find "$KERNEL_DIR" -name '*.rej' -type f)

    warn "有 $REJ_COUNT 个 .rej 冲突文件，已收集到 artifacts/patch-rejects/"
fi
put_env REJ_COUNT "$REJ_COUNT"

section "产物清单"
ls -lh "$OUT_DIR" | sed 's/^/  /'

ok "打包完成"
