#!/usr/bin/env bash
# 应用所有 defconfig 修改 + 设置内核版本串。
#
# 顺序有讲究：base → susfs → droidspaces → 可选特性 → 设备专属。
# 后面的可以覆盖前面的，设备专属片段拥有最高优先级。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_env WORKSPACE REPO_ROOT
KERNEL_DIR="${KERNEL_DIR:-$WORKSPACE/common}"
DEFCONFIG="${DEFCONFIG:-$KERNEL_DIR/arch/arm64/configs/gki_defconfig}"
export KERNEL_DIR DEFCONFIG

require_file "$DEFCONFIG" "gki_defconfig"

section "应用 defconfig 配置"

# 备份原始 defconfig。bazel 构建需要用 diff 提取我们的改动做成 fragment，
# 传统 make 构建也便于排查「我到底改了什么」。
[ -f "$DEFCONFIG.orig" ] || cp "$DEFCONFIG" "$DEFCONFIG.orig"

# --- 基础 -------------------------------------------------------------------
apply_config_fragment "$REPO_ROOT/config/base.config"

# --- SUSFS ------------------------------------------------------------------
if is_true "${ENABLE_SUSFS:-false}"; then
    section "SUSFS 配置"

    # 逐项检查符号是否存在再启用。SUSFS 的子功能在不同版本间会增减，
    # 写了不存在的项会被 kconfig 静默丢弃。
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
            CONFIG_*=y) enable_config_if_defined "${line%%=*}" ;;
        esac
    done < "$REPO_ROOT/config/susfs.config"

    # SukiSU 特有：SUS_SU 是老的 su 隐藏方式，与新的 hook 机制冲突，
    # 上游推荐关掉，改用 KSU_MANUAL_HOOK。
    if config_defined CONFIG_KSU_SUSFS_SUS_SU; then
        disable_config CONFIG_KSU_SUSFS_SUS_SU
    fi
    enable_config_if_defined CONFIG_KSU_MANUAL_HOOK
else
    # 显式关掉，避免 SukiSU 的 Kconfig 默认把它选上
    if config_defined CONFIG_KSU_SUSFS; then
        disable_config CONFIG_KSU_SUSFS
    fi
fi

# --- Droidspaces ------------------------------------------------------------
# 注意：Droidspaces 的配置由 setup-droidspaces.sh 自己应用，
# 因为它必须和 kABI 注入绑在一起 —— 只开 CONFIG_SYSVIPC 而不注入 kABI
# 会造出一个必然 bootloop 的内核。放在同一个脚本里，二者不可能脱节。

# --- 可选特性 ---------------------------------------------------------------
# 同理由 setup-optional.sh 负责。

# --- 设备专属片段 -----------------------------------------------------------
if [ -n "${EXTRA_CONFIG_FRAGMENTS:-}" ]; then
    section "设备专属配置"
    for frag in $EXTRA_CONFIG_FRAGMENTS; do
        apply_config_fragment "$REPO_ROOT/$frag"
    done
fi

# =============================================================================
# 内核版本串
#
# 目标：让 `uname -r` 和 `uname -v` 尽量贴近原厂，减少被检测的可能。
# =============================================================================

section "设置内核版本串"

cd "$KERNEL_DIR"

# --- localversion（影响 uname -r）------------------------------------------

if [ -n "${KERNEL_SUFFIX:-}" ]; then
    FINAL_LOCALVERSION="$KERNEL_SUFFIX"
    log "使用 workflow 指定的后缀"
elif [ -n "${KERNEL_LOCALVERSION:-}" ]; then
    FINAL_LOCALVERSION="$KERNEL_LOCALVERSION"
    log "使用设备配置的后缀"
else
    FINAL_LOCALVERSION="${ANDROID_VERSION}-${KMI_GENERATION:-unknown}"
    warn "设备配置未提供 KERNEL_LOCALVERSION，用兜底值"
fi

ok "内核后缀: -$FINAL_LOCALVERSION"

# setlocalversion 会拼接 git 描述、-dirty 等。直接让它输出固定串。
SETLOCALVERSION="scripts/setlocalversion"
if [ -f "$SETLOCALVERSION" ]; then
    # 替换脚本最后一行的 echo "$res"
    sed -i "\$s|echo \"\\\$res\"|echo \"-${FINAL_LOCALVERSION}\"|" "$SETLOCALVERSION"
    assert_contains "$SETLOCALVERSION" "-${FINAL_LOCALVERSION}" "setlocalversion 后缀替换"
else
    warn "找不到 scripts/setlocalversion"
fi

# 有些路径读 CONFIG_LOCALVERSION 而不是 setlocalversion
if grep -q '^CONFIG_LOCALVERSION=' "$DEFCONFIG"; then
    sed -i "/^CONFIG_LOCALVERSION=/ s|=\"[^\"]*\"|=\"-${FINAL_LOCALVERSION}\"|" "$DEFCONFIG"
fi
# 关掉自动追加 +（源码有未提交改动时 kbuild 会加）
disable_config CONFIG_LOCALVERSION_AUTO

put_env FINAL_LOCALVERSION "$FINAL_LOCALVERSION"

# --- 构建时间戳（影响 uname -v）--------------------------------------------

if [ -n "${FAKE_BUILD_TIME:-}" ]; then
    # 校验格式，格式不对的话 date 解析会失败，产物版本串就成了乱码
    TIME_RE='^(Mon|Tue|Wed|Thu|Fri|Sat|Sun) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) (0[1-9]|[12][0-9]|3[01]) ([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9] UTC [0-9]{4}$'
    [[ "$FAKE_BUILD_TIME" =~ $TIME_RE ]] \
        || die "FAKE_BUILD_TIME 格式错误：'$FAKE_BUILD_TIME'
     应形如 'Wed Sep 10 13:11:53 UTC 2025'（日期两位、星期与日期要对得上）"

    # 星期与日期必须真的匹配，否则一眼就能看出是伪造的
    NORMALIZED="$(LC_ALL=C TZ=UTC date -u -d "$FAKE_BUILD_TIME" +'%a %b %d %T UTC %Y' 2>/dev/null || true)"
    [ "$NORMALIZED" = "$FAKE_BUILD_TIME" ] \
        || die "FAKE_BUILD_TIME 无效：'$FAKE_BUILD_TIME'
     解析后得到 '$NORMALIZED'，星期与日期对不上。"

    DATESTR="$FAKE_BUILD_TIME"
    ok "使用伪造构建时间: $DATESTR"
else
    DATESTR="$(TZ='UTC' date +'%a %b %d %T %Z %Y')"
    log "使用真实构建时间: $DATESTR"
fi

put_env KBUILD_BUILD_TIMESTAMP "$DATESTR"
put_env KBUILD_BUILD_VERSION   "1"

# mkcompile_h 会把时间戳编进 UTS_VERSION。
# KBUILD_BUILD_TIMESTAMP 环境变量在多数情况下够用，
# 但保险起见直接改脚本，确保 "#1 SMP PREEMPT" 前缀也一致。
MKCOMPILE="scripts/mkcompile_h"
if [ -f "$MKCOMPILE" ] && [ -n "${FAKE_BUILD_TIME:-}" ]; then
    if grep -q 'UTS_VERSION=' "$MKCOMPILE"; then
        perl -pi -e "s{UTS_VERSION=\"\\\$\\\(.*?\\\)\"}{UTS_VERSION=\"#1 SMP PREEMPT $DATESTR\"}" \
            "$MKCOMPILE"
        assert_contains "$MKCOMPILE" "#1 SMP PREEMPT $DATESTR" "mkcompile_h 时间戳替换"
        ok "已固定 mkcompile_h 的 UTS_VERSION"
    else
        warn "mkcompile_h 结构不符合预期，仅依赖 KBUILD_BUILD_TIMESTAMP"
    fi
fi

# =============================================================================
# 摘要
# =============================================================================

section "defconfig 改动摘要"
if [ -f "$DEFCONFIG.orig" ]; then
    diff "$DEFCONFIG.orig" "$DEFCONFIG" | grep '^>' | sed 's/^> /  + /' || true
fi

ok "defconfig 应用完成"
