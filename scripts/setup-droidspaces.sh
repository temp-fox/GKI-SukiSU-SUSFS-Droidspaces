#!/usr/bin/env bash
# 集成 Droidspaces 容器支持。
#
# Droidspaces 本身是纯 userspace 程序，不含内核模块。它只「消费」内核能力。
# 所以这个脚本做的全是开配置 + 修 kABI，没有任何 Droidspaces 自己的代码。
#
# 【为什么需要 kABI 补丁】
# 开启 CONFIG_SYSVIPC 会在 task_struct 中间插入 sysvsem / sysvshm 两个字段，
# 位移其后所有成员的偏移量。而 GKI 的厂商模块（GPU / Camera / 音频）是
# 按原偏移量预编译的二进制 —— 偏移一变，它们读到的就是错位的内存。
#
# 表现是刷机后直接 bootloop，没有任何日志。编译期完全正常。
# 这是本项目最危险的失败模式，所以下面的探测是硬失败。
#
# 【解法】
# 把这两个字段挪到 task_struct 尾部的 ANDROID_KABI_RESERVE 槽位里 ——
# 那是 Google 专门预留的填充空间，占用它不影响任何既有字段的偏移。
#
# 【为什么不打官方补丁而是脚本注入】
# 官方补丁 001.GKI-below-6.12-fix_sysvipc_kabi_6_7_8.patch 的 hunk 2 上下文
# 期望 RESERVE(3) 紧邻 RESERVE(4)，而本机源码这里是 #endif（CONFIG_SLIM_SCHED
# 条件块的收尾）—— 差一行。前身项目用 patch -F 3 恰好被 fuzz 吸收，
# 属于运气而非设计，而且那个 -F 3 对所有补丁一律放宽，成了静默失败温床。
#
# 只有两处改动，直接脚本注入更稳：不依赖行号、不依赖上下文、槽位可参数化。
# 官方补丁仍保留在 patches/droidspaces/ 供人工回退。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_env WORKSPACE REPO_ROOT
KERNEL_DIR="${KERNEL_DIR:-$WORKSPACE/common}"
DEFCONFIG="${DEFCONFIG:-$KERNEL_DIR/arch/arm64/configs/gki_defconfig}"
KABI_SLOTS="${KABI_SLOTS:-${DEFAULT_KABI_SLOTS:-6_7_8}}"

export KERNEL_DIR DEFCONFIG
cd "$KERNEL_DIR"

SCHED_H="include/linux/sched.h"
require_file "$SCHED_H"

section "Droidspaces：kABI 槽位探测"

# -----------------------------------------------------------------------------
# 1. 打印 task_struct 尾部的槽位占用全貌
#
# 换机型时这份清单就是选槽位的依据，所以无论成败都打出来。
# -----------------------------------------------------------------------------

log "task_struct 的 ANDROID_KABI 槽位占用："
# 从 task_struct 定义开始截取，避免把其它结构体的槽位混进来
awk '/^struct task_struct \{/{f=1} f && /ANDROID_KABI_(USE|RESERVE)\([0-9]/{
        printf "    %5d: %s\n", NR, $0 }
     f && /^\};/{exit}' "$SCHED_H" | sed 's/\t/  /g'

# -----------------------------------------------------------------------------
# 2. 校验选中的槽位确实空闲
#
# ⚠️ 这里必须硬失败。槽位冲突不产生编译错误，只在刷机后 bootloop。
# -----------------------------------------------------------------------------

read -r S1 S2 S3 <<< "$(echo "$KABI_SLOTS" | tr '_' ' ')"
for s in "$S1" "$S2" "$S3"; do
    [[ "$s" =~ ^[0-9]+$ ]] || die "kabi_slots 格式错误：'$KABI_SLOTS'（应形如 6_7_8）"
done
log "请求使用槽位: $S1 / $S2 / $S3"

# 幂等：已经注入过就直接跳到配置部分
#
# 注意这里要与「槽位无关」地检测：只要树里已经有任何一处 sysvsem 注入，
# 就说明这棵源码树被改过。如果这次请求的槽位与已注入的不一致，必须硬失败 ——
# 否则会在已改过的树上再叠一层，得到两份 sysvsem 定义。
ALREADY_INJECTED=false
if grep -qE 'ANDROID_KABI_USE\([0-9]+, struct sysv_sem' "$SCHED_H"; then
    INJECTED_SLOT="$(grep -oE 'ANDROID_KABI_USE\([0-9]+, struct sysv_sem' "$SCHED_H" \
                     | grep -oE '[0-9]+' | head -1)"
    if [ "$INJECTED_SLOT" = "$S1" ]; then
        skip "kABI 已注入过（槽位 $S1/$S2/$S3），跳过修改"
        ALREADY_INJECTED=true
    else
        die "源码树中已存在 kABI 注入（起始槽位 $INJECTED_SLOT），
     但本次请求的起始槽位是 $S1。

     在已改过的树上换槽位重注入会叠加出两份 sysvsem 定义。
     请清掉源码缓存重新构建，或把 kabi_slots 改回 ${INJECTED_SLOT}_*。"
    fi
fi

if [ "$ALREADY_INJECTED" = false ]; then
    OCCUPIED=()
    for s in "$S1" "$S2" "$S3"; do
        if grep -qE "ANDROID_KABI_USE\(${s}," "$SCHED_H"; then
            OCCUPIED+=("$s")
        fi
    done

    if [ ${#OCCUPIED[@]} -gt 0 ]; then
        die "kABI 槽位 ${OCCUPIED[*]} 已被占用（见上面的清单）。

     继续构建会得到一个能编译、但刷机后直接 bootloop 的内核 ——
     没有日志，最难排查的那种失败。

     请从上面清单里挑三个连续的、状态为 RESERVE 的槽位，
     改 workflow 的 kabi_slots 输入项，或改 devices/*.env 的
     DEFAULT_KABI_SLOTS。

     注意 #ifdef 分支里的 ANDROID_KABI_USE 也算占用 —— 例如
     CONFIG_SLIM_SCHED=y 会占掉槽 2 和 3。"
    fi
    ok "槽位 $S1/$S2/$S3 空闲"
fi

# -----------------------------------------------------------------------------
# 3. 注入
#
# 改动 1：注释掉 task_struct 中间的原字段
# 改动 2：在尾部槽位重新安置
#
# 用 perl -0777 做整体匹配，因为要跨行。每步都验证，失败即中断。
# -----------------------------------------------------------------------------

if [ "$ALREADY_INJECTED" = false ]; then
    section "Droidspaces：注入 SYSVIPC kABI 改动"

    cp "$SCHED_H" "$SCHED_H.kabi.bak"

    # --- 改动 1 ---------------------------------------------------------------
    # 匹配 task_struct 里的：
    #     #ifdef CONFIG_SYSVIPC
    #         struct sysv_sem<tabs>sysvsem;
    #         struct sysv_shm<tabs>sysvshm;
    #     #endif
    # 制表符数量不写死，用 \t+ 兼容不同缩进风格。
    log "改动 1/2：注释掉 task_struct 中的 sysvsem / sysvshm"

    # 先确认原字段确实在、且尚未被注释 —— 否则后面的 grep 验证会假阳性
    # （在一棵已注释的树上，即使 perl 什么都没匹配到，grep 照样能过）
    #
    # 注意用 [[:space:]] 而不是 \t：grep -E 不解释 \t 转义，写 \t 会匹配
    # 字面量反斜杠加 t，导致这条检查永远不成立。
    grep -qE '^[[:space:]]*struct sysv_sem[[:space:]]+sysvsem;' "$SCHED_H" \
        || die "kABI 改动 1 前置检查失败：$SCHED_H 中找不到未注释的 sysvsem 字段。

     期望的源码形态是：
         #ifdef CONFIG_SYSVIPC
             struct sysv_sem<TAB>sysvsem;
             struct sysv_shm<TAB>sysvshm;
         #endif
     实际内容：
$(grep -n -A3 'ifdef CONFIG_SYSVIPC' "$SCHED_H" | head -8 | sed 's/^/         /')"

    perl -0777 -pi -e '
        s{(\#ifdef\ CONFIG_SYSVIPC\n)
          (\t)struct\ sysv_sem\t+sysvsem;\n
          \tstruct\ sysv_shm\t+sysvshm;\n}
         {$1$2// struct sysv_sem\t\tsysvsem;\n\t// struct sysv_shm\t\tsysvshm;\n}x;
    ' "$SCHED_H"

    # 注释已加上，且原字段确实消失了（两个方向都验，防止只加不删）
    if ! grep -qF '// struct sysv_sem' "$SCHED_H" \
       || grep -qE '^[[:space:]]*struct sysv_sem[[:space:]]+sysvsem;' "$SCHED_H"; then
        mv "$SCHED_H.kabi.bak" "$SCHED_H"
        die "kABI 改动 1 失败：perl 替换未生效（已回滚）。

     实际内容：
$(grep -n -A3 'ifdef CONFIG_SYSVIPC' "$SCHED_H" | head -8 | sed 's/^/         /')"
    fi
    ok "  改动 1 完成"

    # --- 改动 2 ---------------------------------------------------------------
    # 把三个连续的 RESERVE 换成 #ifdef 包裹的 USE + REPLACE。
    #
    # 为什么是「一个 USE + 一个 REPLACE 占两槽」：
    #   sysv_sem 是单指针，8 字节，正好一个槽
    #   sysv_shm 含链表头，16 字节，需要两个槽 —— 用 _ANDROID_KABI_REPLACE
    #   把相邻两个 RESERVE 合并成一个 union 来放
    log "改动 2/2：在槽位 $S1/$S2/$S3 安置 sysvsem / sysvshm"
    perl -0777 -pi -e "
        s{\tANDROID_KABI_RESERVE\\(${S1}\\);\n
          \tANDROID_KABI_RESERVE\\(${S2}\\);\n
          \tANDROID_KABI_RESERVE\\(${S3}\\);\n}
         {#ifdef CONFIG_SYSVIPC\n\tANDROID_KABI_USE(${S1}, struct sysv_sem sysvsem);\n\t_ANDROID_KABI_REPLACE(ANDROID_KABI_RESERVE(${S2}); ANDROID_KABI_RESERVE(${S3}), struct sysv_shm sysvshm);\n#else\n\tANDROID_KABI_RESERVE(${S1});\n\tANDROID_KABI_RESERVE(${S2});\n\tANDROID_KABI_RESERVE(${S3});\n#endif\n}x;
    " "$SCHED_H"

    if ! grep -qF "ANDROID_KABI_USE(${S1}, struct sysv_sem" "$SCHED_H"; then
        mv "$SCHED_H.kabi.bak" "$SCHED_H"
        die "kABI 改动 2 失败：未找到连续的三行

         ANDROID_KABI_RESERVE(${S1});
         ANDROID_KABI_RESERVE(${S2});
         ANDROID_KABI_RESERVE(${S3});

     这三个槽位在源码里可能不连续（中间夹着 #ifdef / #else / #endif）。
     请从本步骤开头打印的清单中，挑一组真正连续的槽位。"
    fi

    # 必须且只能有一处注入。
    #
    # 替换文本的 #else 分支会原样重现那三行 RESERVE，所以「在已注入的树上
    # 再跑一次」会在 #else 里再嵌一层，得到两份 sysvsem 定义 —— 编译期报
    # duplicate member，但错误信息指向宏展开后的位置，很难看懂。
    # 上面的 ALREADY_INJECTED 已经拦住了正常路径，这里再兜一道底。
    INJECT_COUNT="$(grep -cE 'ANDROID_KABI_USE\([0-9]+, struct sysv_sem' "$SCHED_H")"
    if [ "$INJECT_COUNT" -ne 1 ]; then
        mv "$SCHED_H.kabi.bak" "$SCHED_H"
        die "kABI 注入后发现 ${INJECT_COUNT} 处 sysvsem 定义，预期恰好 1 处（已回滚）。
     多半是在一棵已注入过的源码树上重复执行了本脚本。
     请清掉源码缓存后重新构建。"
    fi
    ok "  改动 2 完成"

    rm -f "$SCHED_H.kabi.bak"

    log "注入结果："
    grep -n -B1 -A8 "ANDROID_KABI_USE(${S1}, struct sysv_sem" "$SCHED_H" \
        | sed 's/^/    /' | sed 's/\t/  /g'
fi

# -----------------------------------------------------------------------------
# 4. 模块 CRC 校验放宽
#
# kABI 改动会让 task_struct 相关符号的 CRC 变化，厂商预编译模块加载时
# 会因 CRC 不匹配被拒绝。放宽 check_version 让它只告警不拒绝。
#
# 这不是「绕过安全检查」—— 我们恰恰是用 kABI 槽位保证了内存布局不变，
# CRC 变化只是因为源码文本变了。
# -----------------------------------------------------------------------------

section "Droidspaces：放宽模块 CRC 校验"

VERSION_C=""
for c in kernel/module/version.c kernel/module.c; do
    [ -f "$c" ] && { VERSION_C="$c"; break; }
done

if [ -z "$VERSION_C" ]; then
    warn "找不到模块版本校验文件，跳过 CRC 放宽"
elif grep -qF 'But ignore...' "$VERSION_C"; then
    skip "CRC 校验已放宽过"
else
    # 这个补丁上下文简单（就 bad_version 分支那三行），跨版本很稳定，
    # 用 patch 而非 sed：改动内容一目了然，也方便人工核对。
    apply_patch "$REPO_ROOT/patches/droidspaces/disable_module_crc_check.patch" \
                "$KERNEL_DIR" 1
    assert_contains "$VERSION_C" 'But ignore...' "CRC 放宽"
    ok "  已放宽（CRC 不匹配时只告警，不拒绝加载模块）"
fi

# -----------------------------------------------------------------------------
# 5. cgroup 文件名前缀修复
#
# LXC / Droidspaces 期望在 NOPREFIX 模式的 cgroup 根下仍能看到
# "<subsys>.<file>" 形式的文件名。内核在某次改动后不再创建这些别名，
# 导致容器初始化时找不到 cgroup 控制文件。
# -----------------------------------------------------------------------------

section "Droidspaces：cgroup 前缀兼容"

CGROUP_C="kernel/cgroup/cgroup.c"
if [ ! -f "$CGROUP_C" ]; then
    warn "找不到 $CGROUP_C，跳过 cgroup 修复"
elif grep -qF 'CGRP_ROOT_NOPREFIX' "$CGROUP_C" \
     && grep -qF 'CFTYPE_NO_PREFIX' "$CGROUP_C"; then
    skip "cgroup 前缀修复已应用过"
else
    apply_patch "$REPO_ROOT/patches/droidspaces/fix_cgroup.patch" "$KERNEL_DIR" 1
    assert_contains "$CGROUP_C" 'CGRP_ROOT_NOPREFIX' "cgroup 前缀修复"
    ok "  cgroup 前缀修复完成"
fi

# -----------------------------------------------------------------------------
# 6. 厂商专属修复：oplus_bsp_midas
#
# OPPO / 一加 / realme 的功耗统计模块 oplus_bsp_midas 调用
# find_task_by_vpid() 后不判空直接解引用。容器场景下大量进程处于
# 独立 PID namespace，该模块频繁查不到 → 开机即 panic。
#
# 修复方式：查不到时，如果调用方是这个模块，返回一个哨兵任务而非 NULL。
# -----------------------------------------------------------------------------

if is_true "${NEEDS_OPLUS_MIDAS_FIX:-false}"; then
    section "Droidspaces：oplus_bsp_midas 空指针修复"

    PID_C="kernel/pid.c"
    require_file "$PID_C"

    if grep -qF 'ghost-task-sentinel' "$PID_C"; then
        skip "midas 修复已应用过"
    else
        MIDAS_PATCH="$REPO_ROOT/patches/vendor/oplus/fix_oplus_bsp_midas.patch"
        require_file "$MIDAS_PATCH" "midas 修复补丁"

        # 这个补丁失败 = 开机 panic，所以不吞异常
        apply_patch "$MIDAS_PATCH" "$KERNEL_DIR" 1

        # 三处关键改动都得在
        assert_contains "$PID_C" 'ghost-task-sentinel'  "midas: 哨兵任务定义"
        assert_contains "$PID_C" 'oplus_bsp_midas'      "midas: 模块名判断"
        assert_contains "$PID_C" 'init_ghost_task();'   "midas: 初始化调用点"
        ok "  midas 修复已生效（三处关键改动均已验证）"
    fi
fi

# -----------------------------------------------------------------------------
# 7. 内核配置
# -----------------------------------------------------------------------------

section "Droidspaces：内核配置"

apply_config_fragment "$REPO_ROOT/config/droidspaces.config"

ok "Droidspaces 集成完成（kABI 槽位 $KABI_SLOTS）"
put_env DROIDSPACES_KABI_SLOTS "$KABI_SLOTS"
