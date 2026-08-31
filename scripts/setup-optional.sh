#!/usr/bin/env bash
# 可选特性：KPM / 网络扩展 / zram / Re-Kernel / BBR / NTsync / BBG
#
# 每个特性一段，各自独立开关、独立验证。
# 加新特性就在下面追加一段，不用改其他地方。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_env WORKSPACE REPO_ROOT
KERNEL_DIR="${KERNEL_DIR:-$WORKSPACE/common}"
DEFCONFIG="${DEFCONFIG:-$KERNEL_DIR/arch/arm64/configs/gki_defconfig}"
export KERNEL_DIR DEFCONFIG

cd "$KERNEL_DIR"

# =============================================================================
# KPM —— SukiSU 的内核补丁模块框架
# =============================================================================

if is_true "${ENABLE_KPM:-false}"; then
    section "可选特性：KPM"

    # KPM 由 SukiSU 提供，先确认所选分支真的有这个符号。
    # 没有的话写进 defconfig 也会被 kconfig 静默丢弃 —— 构建照样成功，
    # 但管理器里看不到 KPM 页面，用户会以为是别的问题。
    if config_defined CONFIG_KPM; then
        apply_config_fragment "$REPO_ROOT/config/kpm.config"
        ok "KPM 已启用"
    else
        die "请求启用 KPM，但当前 SukiSU 版本（ksu_ref=$KSU_REF）未声明 CONFIG_KPM。
     换一个含 KPM 的 SukiSU 分支，或关闭 enable_kpm。"
    fi
fi

# =============================================================================
# 网络功能扩展
# =============================================================================

if is_true "${ENABLE_NETWORK_EXT:-false}"; then
    section "可选特性：网络功能扩展"
    apply_config_fragment "$REPO_ROOT/config/network.config"
    ok "网络扩展已启用"
fi

# =============================================================================
# zram
# =============================================================================

if is_true "${ENABLE_ZRAM:-false}"; then
    section "可选特性：zram"

    apply_config_fragment "$REPO_ROOT/config/zram.config"

    # ⚠️ 不要把 ZRAM/ZSMALLOC 改成内建（=y）。
    #
    # 本项目早期版本这么做过，代价是刷入后所有 app 都打不开：
    # 原厂的 oplus_bsp_hybridswap_zram 模块会在 memcg 里注册 15 个私有控制
    # 文件，其中 memory.app_uid 是 libprocessgroup 建进程组时硬编码要写的。
    # 编成内建后该模块加载不了，文件不存在，Zygote 每 fork 一个 app 就 abort。
    # 详见 config/zram.config 的注释。
    #
    # 保持 =m 时仍会产出 zram.ko / zsmalloc.ko，modules.bzl 的声明依然成立，
    # 所以这里不需要（也不允许）动 modules.bzl。
    MODULES_BZL="$KERNEL_DIR/modules.bzl"
    if [ -f "$MODULES_BZL" ] \
       && ! grep -qE '"(drivers/block/zram/zram|mm/zsmalloc)\.ko"' "$MODULES_BZL"; then
        die "modules.bzl 里缺少 zram.ko / zsmalloc.ko 声明。

     这通常意味着源码树被旧版脚本改过（旧版会在改内建时删掉这两行），
     而当前配置是 ZRAM=m —— 两者不匹配会导致模块产出后无人认领。
     请清掉源码缓存重新构建。"
    fi

    ok "zram 已启用（模块形式，与原厂一致）"
fi

# =============================================================================
# Re-Kernel —— 改善后台进程冻结/唤醒行为
#
# 上游 Sakion-Team/Re-Kernel 当前对 Android 5.10+ / GKI 的推荐形态是 LKM：
# README_CN 写明内核 >= 5.10 使用 Magisk 模块或手动 insmod；上游自己的
# build-lkm/ddk-lkm workflow 也是把 LKM-Source 编译成 rekernel.ko。
# Integrate/rekernel/ 是给 <= 5.4 或非 GKI/QGKI 内核做源码级集成的旧路径。
#
# 因此不能再把 LKM-Source 强行改成 in-tree 驱动塞进 6.1 GKI 的 Image：
# 这和上游支持路径相反，并且用户已在 RMX5062 上实测会卡死/重启。
# 参考 sm8650_kernel 的 newrealme flow，它只写 CONFIG_REKERNEL=y，没有拉取
# LKM-Source 强转 in-tree；若源码树本身没有 Re-Kernel Kconfig，这一步实际会
# 被 Kconfig 丢弃，不会把 Re-Kernel 编进内核。
# =============================================================================

if is_true "${ENABLE_REKERNEL:-false}"; then
    section "可选特性：Re-Kernel"

    REK_SRC="$WORKSPACE/Re-Kernel"
    if [ ! -d "$REK_SRC/.git" ]; then
        rm -rf "$REK_SRC"
        log "克隆 Sakion-Team/Re-Kernel（只用于核对上游支持形态，不强转 in-tree）"
        git clone --depth=1 https://github.com/Sakion-Team/Re-Kernel.git "$REK_SRC" \
            || die "无法克隆 Re-Kernel"
    fi

    require_dir "$REK_SRC/LKM-Source" "Re-Kernel LKM 源码目录"
    require_dir "$REK_SRC/Integrate/rekernel" "Re-Kernel 旧 in-tree 集成目录"

    if config_defined CONFIG_REKERNEL; then
        enable_config CONFIG_REKERNEL

        # 参考 newrealme flow 只启用 CONFIG_REKERNEL，本项目不默认打开网络监听。
        # 上游 Integrate Kconfig 里 CONFIG_REKERNEL_NETWORK 默认 n；LKM 新版也只在
        # 用户态显式 monitor uid 后才监听网络。这里保持最小化，避免扩大不稳定面。
        if config_defined CONFIG_REKERNEL_NETWORK; then
            disable_config CONFIG_REKERNEL_NETWORK
        fi

        ok "Re-Kernel 已按现有源码树的原生 Kconfig 启用"
    else
        die "请求启用 Re-Kernel，但当前 RMX5062 6.1 GKI 源码树没有原生 CONFIG_REKERNEL。

     已核对上游 Sakion-Team/Re-Kernel：Android 5.10+ / GKI 推荐编译 rekernel.ko
     作为 LKM 使用；Integrate/rekernel 是给 <=5.4 或非 GKI/QGKI 内核的源码级
     集成路径。旧脚本把 LKM-Source 强行转成 in-tree 驱动编进 Image，这不是上游
     6.1 GKI 支持方式，且已被实机验证会卡死/重启。

     因此这里改为硬失败，避免继续产出危险 AK3。需要 Re-Kernel 时应单独按上游
     LKM/DDK 路径构建 rekernel.ko；本内核 AK3 默认不再内建 Re-Kernel。"
    fi
fi

# =============================================================================
# BBR
# =============================================================================

if is_true "${ENABLE_BBR:-false}"; then
    section "可选特性：BBR 拥塞控制"
    apply_config_fragment "$REPO_ROOT/config/bbr.config"

    if is_true "${BBR_AS_DEFAULT:-false}"; then
        set_config CONFIG_DEFAULT_TCP_CONG '"bbr"'
        ok "BBR 已设为默认拥塞控制算法"
    else
        ok "BBR 已编入内核（默认算法仍是 cubic，可用 sysctl 切换）"
    fi
fi

# =============================================================================
# NTsync —— Wine/Proton 的同步原语
#
# ⚠️ 与 Droidspaces 无关，是 Winlator（在安卓上跑 Windows 程序）需要的。
#    默认关闭还有个安全原因：上游补丁会把 /dev/ntsync 设成 0666 并伪装成
#    gpu_device SELinux 上下文，等于任意 App 都能访问这个设备节点。
#    日用机型上这不是个好默认值。
# =============================================================================

if is_true "${ENABLE_NTSYNC:-false}"; then
    section "可选特性：NTsync"

    warn "NTsync 会把 /dev/ntsync 开放给所有 App（0666 + gpu_device 上下文）。"
    warn "  这是 Winlator 的需求。若你不跑 Winlator，建议关掉这一项。"

    NTSYNC_COMPAT="ntsync_compat_${ANDROID_VERSION}-${KERNEL_VERSION}"
    NTSYNC_BASE="$REPO_ROOT/patches/optional/ntsync/ntsync_base.patch"
    NTSYNC_VER="$REPO_ROOT/patches/optional/ntsync/${NTSYNC_COMPAT}.patch"

    if [ ! -f "$NTSYNC_BASE" ] || [ ! -f "$NTSYNC_VER" ]; then
        # 补丁体积大（30KB+），不进仓库，构建时按需下载
        log "从上游获取 NTsync 补丁"
        mkdir -p "$(dirname "$NTSYNC_BASE")"
        BASE_URL="https://raw.githubusercontent.com/Goldzxcbug/Droidspaces_Kernel_patch/main/NTsync"
        curl -fsSL "$BASE_URL/ntsync_base.patch" -o "$NTSYNC_BASE" \
            || die "无法下载 ntsync_base.patch"
        curl -fsSL "$BASE_URL/${NTSYNC_COMPAT}.patch" -o "$NTSYNC_VER" \
            || die "无法下载 ${NTSYNC_COMPAT}.patch —— 该内核版本可能没有适配"
    fi

    apply_patch "$NTSYNC_BASE" "$KERNEL_DIR" 1
    apply_patch "$NTSYNC_VER"  "$KERNEL_DIR" 1
    assert_no_rejects "$KERNEL_DIR" "NTsync 补丁"

    enable_config CONFIG_NTSYNC
    ok "NTsync 已启用"
fi

# =============================================================================
# BBG（Baseband Guard）—— 阻止对非用户分区的写入，防误刷变砖
#
# 默认关闭：它会改 security/Kconfig 的 LSM 默认串，与 SELinux/SUSFS
# 有潜在交互。等主链路稳定后再开。
# =============================================================================

if is_true "${ENABLE_BBG:-false}"; then
    section "可选特性：基带保护 BBG"

    BBG_SRC_DIR="$KERNEL_DIR/security/baseband-guard"

    if [ -d "$BBG_SRC_DIR" ]; then
        skip "BBG 已集成"
    else
        log "运行上游 setup.sh"
        # 下载到本地再执行，失败时能看到内容
        curl -fsSL "https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh" \
             -o /tmp/bbg-setup.sh || die "无法下载 BBG setup.sh"
        [ -s /tmp/bbg-setup.sh ] || die "下载到的 BBG setup.sh 是空文件"
        ( cd "$KERNEL_DIR" && bash /tmp/bbg-setup.sh ) || die "BBG setup.sh 执行失败"
        require_dir "$BBG_SRC_DIR" "BBG 源码"
    fi

    # 把 baseband_guard 加进 LSM 默认启用串。
    # 只在 config LSM 的 default 行上动手，且已包含时不重复添加。
    SEC_KCONFIG="$KERNEL_DIR/security/Kconfig"
    if ! grep -q 'baseband_guard' "$SEC_KCONFIG"; then
        sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' \
            "$SEC_KCONFIG"
        assert_contains "$SEC_KCONFIG" 'baseband_guard' "BBG 加入 LSM 串"
    fi

    enable_config CONFIG_BBG
    ok "BBG 已启用"
fi

# =============================================================================
# config_data 伪装 —— 让 /proc/config.gz 不暴露改装痕迹
#
# CONFIG_IKCONFIG_PROC=y 时内核把 .config 原样嵌进镜像，运行时经
# /proc/config.gz 暴露给任何进程（不需要 root 就能读）。CONFIG_KSU=y、
# CONFIG_KSU_SUSFS=y 这些项就明晃晃写在里面 —— 检测方读一次就知道
# 这台设备装了 root 方案，SUSFS 在文件系统层做的隐藏在这里被整个绕过。
#
# 补丁只改 config_data 这个**产物副本**，不动 .config 本身，
# 所以内核功能与不开这个特性时完全一致，只有显示内容变了。
#
# ⚠️ 这不是万能的：内核符号表、/proc/kallsyms、模块列表等仍有痕迹
#    （那些由 SUSFS 的 HIDE_KSU_SUSFS_SYMBOLS 负责）。
#    这一项只堵 /proc/config.gz 这一个口子。
# =============================================================================

if is_true "${ENABLE_CONFIG_SPOOF:-false}" || is_true "${ENABLE_NETWORK_EXT:-false}"; then
    section "可选特性：config_data 伪装"

    apply_patch "$REPO_ROOT/patches/optional/config_data_spoof.patch" "$KERNEL_DIR" 1
    assert_no_rejects "$KERNEL_DIR" "config_data 伪装补丁"

    # 没开 IKCONFIG_PROC 的话 /proc/config.gz 根本不存在，伪装无意义。
    # 不是错误，但要说清楚，否则用户会以为开关没生效。
    if ! grep -q '^CONFIG_IKCONFIG_PROC=y' "$DEFCONFIG"; then
        warn "CONFIG_IKCONFIG_PROC 未启用 —— /proc/config.gz 本就不存在，"
        warn "  伪装补丁虽已应用，但没有实际作用。"
    fi

    SPOOF_RULES=""

    # root 痕迹伪装仍由 ENABLE_CONFIG_SPOOF 控制。
    # 可用 workflow 输入 config_spoof_rules 覆盖，格式 "符号=值" 空格分隔。
    if is_true "${ENABLE_CONFIG_SPOOF:-false}"; then
        SPOOF_RULES="${CONFIG_SPOOF_RULES:-CONFIG_KSU=n CONFIG_KSU_SUSFS=n CONFIG_KPM=n}"
    fi

    # CONFIG_IP6_NF_NAT=n 对齐 sm8650_kernel 的 better_net 流程：
    # 实际内核仍启用 IPv6 NAT，只在网络扩展开启时把 config_data 里的显示值改成 n。
    if is_true "${ENABLE_NETWORK_EXT:-false}" \
       && ! [[ " $SPOOF_RULES " == *" CONFIG_IP6_NF_NAT="* ]]; then
        SPOOF_RULES="${SPOOF_RULES:+$SPOOF_RULES }CONFIG_IP6_NF_NAT=n"
    fi

    log "伪装规则: $SPOOF_RULES"
    put_env KERNEL_CONFIG_SPOOF "$SPOOF_RULES"

    ok "config_data 伪装已启用（编译时生效，产物中 /proc/config.gz 将显示伪装值）"
fi

section "可选特性处理完毕"
