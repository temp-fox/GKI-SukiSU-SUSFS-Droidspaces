#!/usr/bin/env bash
# 编译前自检：确认所有请求的特性都真的进了 .config，且没有互斥项。
#
# 【为什么要有这一步】
# defconfig 里写了配置项，不代表它最终会进 .config：
#   - Kconfig 里没定义这个符号 → 静默丢弃
#   - 依赖项没满足 → 静默降级为 n
#   - 被其他选项 select 关掉 → 静默覆盖
#
# 这些都不会报错，编译照常通过，产物看起来正常，直到刷进手机才发现
# 「SUSFS 没生效」「Droidspaces 还是缺那两项」。
#
# 所以在 `make gki_defconfig` 之后、`make Image` 之前，
# 拿最终的 out/.config 逐项核对。任何一项对不上就中止。
#
# 用法：在 make gki_defconfig 之后、make Image 之前调用。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_env WORKSPACE
KERNEL_DIR="${KERNEL_DIR:-$WORKSPACE/common}"
CFG="${OUT_CONFIG:-$KERNEL_DIR/out/.config}"

require_file "$CFG" "生成的 .config（应由 make gki_defconfig 产出）"

section "编译前配置自检"

FAIL=0

# 必须存在且为 y
need_y() {
    local cfg="$1" why="$2"
    if grep -q "^${cfg}=y\$" "$CFG"; then
        printf '  [✓] %-45s\n' "$cfg"
    else
        printf '  [✗] %-45s ← %s\n' "$cfg" "$why"
        # 打印它在 .config 里的实际状态，帮助判断是没定义还是被降级
        local actual
        actual="$(grep -E "^(# )?${cfg}[ =]" "$CFG" | head -1 || true)"
        [ -n "$actual" ] && printf '      实际: %s\n' "$actual" \
                         || printf '      实际: 该符号完全不在 .config 中（Kconfig 未定义或依赖未满足）\n'
        FAIL=1
    fi
}

# 必须不存在或不为 y
need_not_y() {
    local cfg="$1" why="$2"
    if grep -q "^${cfg}=y\$" "$CFG"; then
        printf '  [✗] %-45s ← %s\n' "$cfg" "$why"
        FAIL=1
    else
        printf '  [✓] %-45s (未启用，符合预期)\n' "$cfg"
    fi
}

# -----------------------------------------------------------------------------
# KernelSU
# -----------------------------------------------------------------------------

if is_true "${ENABLE_KSU:-true}"; then
    log "KernelSU:"
    need_y CONFIG_KSU "root 功能的总开关"
    need_not_y CONFIG_KSU_DISABLE_MANAGER "启用它管理器 App 将无法被内核识别"
    need_not_y CONFIG_KSU_DISABLE_POLICY   "启用它会关掉 App Profile 授权机制"
fi

# -----------------------------------------------------------------------------
# SUSFS —— 本项目的核心目标
# -----------------------------------------------------------------------------

if is_true "${ENABLE_SUSFS:-false}"; then
    log "SUSFS:"
    need_y CONFIG_KSU_SUSFS "SUSFS 总开关。没有它 ksud susfs 全线不可用"

    # 主要子功能。缺哪个都不会导致构建失败，但会让对应能力静默消失。
    for c in CONFIG_KSU_SUSFS_SUS_PATH \
             CONFIG_KSU_SUSFS_SUS_MOUNT \
             CONFIG_KSU_SUSFS_SUS_KSTAT \
             CONFIG_KSU_SUSFS_SPOOF_UNAME \
             CONFIG_KSU_SUSFS_ENABLE_LOG; do
        need_y "$c" "SUSFS 子功能"
    done

    # 内核侧文件必须真的在树里 —— 光有配置项不够
    require_file "$KERNEL_DIR/fs/susfs.c" "SUSFS 实现文件"
    printf '  [✓] %-45s\n' "fs/susfs.c 存在"
fi

# -----------------------------------------------------------------------------
# Droidspaces
#
# 这七项精确对应用户实测缺失的 4 项 + 它们的依赖。
# -----------------------------------------------------------------------------

if is_true "${ENABLE_DROIDSPACES:-false}"; then
    log "Droidspaces:"
    need_y CONFIG_PID_NS        "实测缺失项：PID namespace（MUST HAVE）"
    need_y CONFIG_IPC_NS        "实测缺失项：IPC namespace（MUST HAVE）"
    need_y CONFIG_SYSVIPC       "IPC_NS 的依赖"
    need_y CONFIG_POSIX_MQUEUE  "IPC_NS 的依赖"
    need_y CONFIG_DEVTMPFS      "实测缺失项：devtmpfs（RECOMMENDED）"
    need_y CONFIG_USER_NS       "实测缺失项：User namespace（OPTIONAL）"
    need_y CONFIG_NAMESPACES    "所有 namespace 的总开关"
    need_y CONFIG_NETFILTER_XT_MATCH_ADDRTYPE "Droidspaces 官方 GKI 推荐项"

    # --- kABI 注入必须生效 -------------------------------------------------
    #
    # ⚠️ 这是最重要的一条。CONFIG_SYSVIPC=y 但 kABI 没注入 =
    # 能编译、能刷入、开机 bootloop，且没有任何日志。
    SCHED_H="$KERNEL_DIR/include/linux/sched.h"
    if grep -qF 'ANDROID_KABI_USE' "$SCHED_H" \
       && grep -qF 'struct sysv_sem sysvsem' "$SCHED_H"; then
        printf '  [✓] %-45s\n' "kABI 已把 sysvsem 移入预留槽位"
    else
        printf '  [✗] %-45s ← %s\n' "kABI 注入" \
            "CONFIG_SYSVIPC=y 但 sysvsem 未移入 kABI 槽位 —— 刷机后必然 bootloop"
        FAIL=1
    fi

    # 原字段必须已被注释掉，否则等于插了两遍
    if grep -qF '// struct sysv_sem' "$SCHED_H"; then
        printf '  [✓] %-45s\n' "task_struct 中的原 sysvsem 已注释"
    else
        printf '  [✗] %-45s ← %s\n' "原字段注释" \
            "sysvsem 仍在 task_struct 原位置，偏移量还是会变"
        FAIL=1
    fi

    # --- 厂商修复 -----------------------------------------------------------
    if is_true "${NEEDS_OPLUS_MIDAS_FIX:-false}"; then
        if grep -qF 'ghost-task-sentinel' "$KERNEL_DIR/kernel/pid.c"; then
            printf '  [✓] %-45s\n' "oplus midas 修复已生效"
        else
            printf '  [✗] %-45s ← %s\n' "oplus midas 修复" \
                "补丁未生效，开机会因 oplus_bsp_midas 空指针 panic"
            FAIL=1
        fi
    fi
fi

# -----------------------------------------------------------------------------
# 可选特性
# -----------------------------------------------------------------------------

if is_true "${ENABLE_KPM:-false}"; then
    log "KPM:"
    need_y CONFIG_KPM "KPM 框架"
    need_y CONFIG_KALLSYMS_ALL "KPM 需要完整符号表来定位补丁点"
fi

if is_true "${ENABLE_NETWORK_EXT:-false}"; then
    log "网络扩展:"
    need_y CONFIG_IP_SET "ipset 支持"
    need_y CONFIG_NETFILTER_XT_SET "iptables -m set"
fi

if is_true "${ENABLE_ZRAM:-false}"; then
    log "zram:"
    need_y CONFIG_ZRAM "zram 设备"
    need_y CONFIG_ZSMALLOC "zram 的后端分配器"
fi

if is_true "${ENABLE_REKERNEL:-false}"; then
    log "Re-Kernel:"
    need_y CONFIG_REKERNEL "Re-Kernel 驱动"
fi

if is_true "${ENABLE_BBR:-false}"; then
    log "BBR:"
    need_y CONFIG_TCP_CONG_BBR "BBR 算法"
    need_y CONFIG_NET_SCH_FQ "BBR 依赖 fq 的 pacing"
fi

if is_true "${ENABLE_NTSYNC:-false}"; then
    log "NTsync:"
    need_y CONFIG_NTSYNC "NTsync 设备"
fi

if is_true "${ENABLE_BBG:-false}"; then
    log "BBG:"
    need_y CONFIG_BBG "基带保护"
fi

# -----------------------------------------------------------------------------

section "自检结果"

if [ "$FAIL" -ne 0 ]; then
    die "配置自检未通过（见上面标 [✗] 的项）。

     常见原因：
     1. Kconfig 里没有这个符号 —— 说明所选的 SukiSU / SUSFS 分支不含该功能
     2. 依赖项没满足 —— 看 .config 里该符号的实际状态
     3. 补丁没打上 —— 检查前面步骤有没有 .rej

     不要为了让构建通过而删掉这里的检查项。
     这些检查存在的意义就是替代「刷完机才发现有问题」。"
fi

ok "全部配置项校验通过"

# 把关键配置打印出来存档，方便日后对照产物排查
section "最终配置摘要"
grep -E '^CONFIG_(KSU|KPM|ZRAM|REKERNEL|NTSYNC|BBG|PID_NS|IPC_NS|SYSVIPC|POSIX_MQUEUE|DEVTMPFS|USER_NS|NAMESPACES|IP_SET|TCP_CONG_BBR)' \
     "$CFG" | sort | sed 's/^/  /'
