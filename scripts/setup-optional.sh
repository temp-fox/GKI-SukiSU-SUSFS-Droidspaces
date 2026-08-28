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

    # ⚠️ 关键一步：把 zram/zsmalloc 从模块改成内建后，就不再产出 .ko，
    #    但 modules.bzl 仍然声明着它们，构建会因「声明了却没产出」而失败。
    MODULES_BZL="$KERNEL_DIR/modules.bzl"
    if [ -f "$MODULES_BZL" ]; then
        if grep -qE '"(drivers/block/zram/zram|mm/zsmalloc)\.ko"' "$MODULES_BZL"; then
            log "从 modules.bzl 移除 zram.ko / zsmalloc.ko 声明"
            cp "$MODULES_BZL" "$MODULES_BZL.bak"
            sed -i 's|"drivers/block/zram/zram\.ko",||g; s|"mm/zsmalloc\.ko",||g' "$MODULES_BZL"

            grep -qE '"(drivers/block/zram/zram|mm/zsmalloc)\.ko"' "$MODULES_BZL" \
                && die "modules.bzl 清理失败，构建会在模块检查阶段报错" \
                || { rm -f "$MODULES_BZL.bak"; ok "  modules.bzl 已清理"; }
        else
            skip "  modules.bzl 中已无 zram/zsmalloc 声明"
        fi
    else
        skip "  无 modules.bzl（非 bazel 构建），无需清理"
    fi

    ok "zram 已启用"
fi

# =============================================================================
# Re-Kernel —— 改善后台进程冻结/唤醒行为
#
# 上游 Sakion-Team/Re-Kernel 提供两种形态：
#   Integrate/rekernel/  in-tree 版
#   LKM-Source/          外置模块版（源码更完整，上游主要维护这份）
# 我们要内建，所以拿 LKM-Source 的源码，把 Makefile/Kconfig 改成 in-tree 形式。
# =============================================================================

if is_true "${ENABLE_REKERNEL:-false}"; then
    section "可选特性：Re-Kernel"

    REK_DIR="$KERNEL_DIR/drivers/rekernel"

    if [ -d "$REK_DIR" ] && [ -f "$REK_DIR/Kconfig" ]; then
        skip "Re-Kernel 已集成"
    else
        TMP_REK=/tmp/rekernel
        rm -rf "$TMP_REK"
        log "克隆 Sakion-Team/Re-Kernel"
        git clone --depth=1 https://github.com/Sakion-Team/Re-Kernel.git "$TMP_REK" \
            || die "无法克隆 Re-Kernel"

        require_dir "$TMP_REK/LKM-Source" "Re-Kernel 源码目录"
        rm -rf "$REK_DIR"
        mkdir -p "$REK_DIR"
        cp -a "$TMP_REK/LKM-Source/." "$REK_DIR/"

        # --- 外置模块 → in-tree 驱动 -------------------------------------
        REK_MK="$REK_DIR/Makefile"
        require_file "$REK_MK" "Re-Kernel Makefile"

        # obj-m := rekernel.o  →  obj-$(CONFIG_REKERNEL) += rekernel.o
        sed -i 's|^obj-m *:= *rekernel\.o$|obj-$(CONFIG_REKERNEL) += rekernel.o|' "$REK_MK"
        assert_contains "$REK_MK" 'obj-$(CONFIG_REKERNEL)' "Re-Kernel Makefile 转 in-tree"

        grep -qF 'ccflags-$(CONFIG_REKERNEL_LEGACY_NETLINK) += -DLEGACY_NETLINK' "$REK_MK" \
            || echo 'ccflags-$(CONFIG_REKERNEL_LEGACY_NETLINK) += -DLEGACY_NETLINK' >> "$REK_MK"

        # in-tree 编译不需要 depends on MODULES，留着会让选项无法选中
        sed -i '/^[[:space:]]*depends on MODULES[[:space:]]*$/d' "$REK_DIR/Kconfig"

        # --- 挂载到驱动树 -------------------------------------------------
        DRV_KCONFIG="$KERNEL_DIR/drivers/Kconfig"
        DRV_MAKEFILE="$KERNEL_DIR/drivers/Makefile"

        if ! grep -qF 'source "drivers/rekernel/Kconfig"' "$DRV_KCONFIG"; then
            sed -i '/^endmenu$/i source "drivers/rekernel/Kconfig"' "$DRV_KCONFIG"
            assert_contains "$DRV_KCONFIG" 'source "drivers/rekernel/Kconfig"' \
                "Re-Kernel Kconfig 挂载"
        fi

        if ! grep -qF 'obj-$(CONFIG_REKERNEL) += rekernel/' "$DRV_MAKEFILE"; then
            echo 'obj-$(CONFIG_REKERNEL) += rekernel/' >> "$DRV_MAKEFILE"
        fi

        # --- 修正 include 路径 --------------------------------------------
        # 外置模块用尖括号包含 binder 内部头，in-tree 编译得用引号相对路径
        REK_BINDER="$REK_DIR/rekernel_binder.c"
        if [ -f "$REK_BINDER" ]; then
            sed -i 's|#include <../android/binder_internal.h>|#include "../android/binder_internal.h"|g' \
                "$REK_BINDER"
            # binder_internal.h 用了 DEFINE_SHOW_ATTRIBUTE，需要 seq_file.h
            grep -qF '#include <linux/seq_file.h>' "$REK_BINDER" \
                || sed -i '/#include <linux\/kprobes.h>/a #include <linux/seq_file.h>' "$REK_BINDER"
        fi

        rm -rf "$TMP_REK"
        ok "Re-Kernel 源码已集成为 in-tree 驱动"
    fi

    enable_config CONFIG_REKERNEL
    enable_config_if_defined CONFIG_REKERNEL_NETWORK
    ok "Re-Kernel 已启用"
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

    if [ -d "$KERNEL_DIR/security/baseband_guard" ]; then
        skip "BBG 已集成"
    else
        log "运行上游 setup.sh"
        # 下载到本地再执行，失败时能看到内容
        curl -fsSL "https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh" \
             -o /tmp/bbg-setup.sh || die "无法下载 BBG setup.sh"
        [ -s /tmp/bbg-setup.sh ] || die "下载到的 BBG setup.sh 是空文件"
        ( cd "$KERNEL_DIR" && bash /tmp/bbg-setup.sh ) || die "BBG setup.sh 执行失败"
        require_dir "$KERNEL_DIR/security/baseband_guard" "BBG 源码"
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

section "可选特性处理完毕"
