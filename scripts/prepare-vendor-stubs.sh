#!/usr/bin/env bash
# 修复源码 zip 打包丢失的符号链接目标。
#
# 【问题根源】
# 厂商开源仓库里 kernel/ 树通过符号链接引用 vendor/ 下的私有代码。
# GitHub 打 zip 时不跟随仓库外的链接，解压后这些 symlink 会退化成
# 「内容为目标相对路径的纯文本文件」—— 编译时被当成 C 源码或头文件
# 读取，直接报语法错误或找不到文件。
#
# 【处理方式】
# 1. 全树扫描，自动识别所有「退化的 symlink」（小文件 + 内容是个
#    不存在的相对路径）
# 2. 对目录型目标：生成带空 Kconfig / Makefile 的占位目录
# 3. 对已知的头文件 / 源文件目标：生成 no-op 实现（内容按 vendor 分类）
# 4. 对未知目标：生成最小占位并告警，让人知道有新的断链出现
#
# 【幂等】
# 若某天官方补全了 vendor/，扫描不到断链，脚本什么都不做。
# 已生成过的占位也会被识别并跳过。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_env WORKSPACE
KERNEL_DIR="${KERNEL_DIR:-$WORKSPACE/common}"
require_dir "$KERNEL_DIR"

if ! is_true "${NEEDS_VENDOR_STUBS:-false}"; then
    skip "NEEDS_VENDOR_STUBS 未开启，跳过 vendor 占位生成"
    exit 0
fi

section "扫描断裂的符号链接"

cd "$KERNEL_DIR"

# -----------------------------------------------------------------------------
# 第 1 步：全树扫描，找出指向仓库外、目标不存在的链接
#
# 有两种形态，都要处理：
#
#   A. 悬空的真 symlink（本机型的实际形态）
#      GitHub 打 zip 时会把仓库内的 symlink 原样保留为 symlink，
#      但它们指向 ../../../../vendor/...（仓库外），解压后必然悬空。
#      本机型有 8 处，例如 drivers/soc/oplus/oplus_resctrl。
#
#   B. 退化成纯文本的 symlink
#      某些打包方式会把 symlink 变成「内容为目标路径的小文件」。
#      保留这条判定，换个源或换台机器时仍能覆盖。
#
# ⚠️ 必须按「目标能否解析」来区分，不能按「是不是 symlink」。
#    内核自带一批仓库内的相对链接（scripts/dtc/include-prefixes/arm64
#    -> ../../../arch/arm64/boot/dts 之类），它们目标存在、完全正常，
#    动了会破坏 dtc 的头文件搜索路径。
#
# 判定条件：
#   - 是 symlink，且目标解析不到（-e 为假）；或
#   - 是普通文件、< 200 字节、内容单行无空白、以 ../ 开头、目标不存在
# -----------------------------------------------------------------------------

declare -a BROKEN_PATHS=()   # 断链文件在 KERNEL_DIR 下的相对路径
declare -a BROKEN_TARGETS=() # 它声称指向的目标（相对文件所在目录）

# 本脚本只负责 vendor/ 下的厂商私有代码。有些悬空链接是构建流程自己
# 建的挂载点，指向 $WORKSPACE 下的兄弟目录，**必须原样留着**。
#
# ⚠️ drivers/kernelsu 是踩过的坑，代价是连续 4 次 CI 失败：
#    SukiSU 官方 setup.sh 建 drivers/kernelsu -> ../../KernelSU/kernel，
#    目标在 common/ 之外。而源码缓存只存 common/，KernelSU/ 不在其中，
#    所以缓存命中的那一刻这条链接必然悬空 —— 完美符合下面的断链判定。
#    它会被当成 vendor 断链，由通用兜底 make_dir_stub 造出一个
#    只含空 Kconfig/Makefile 的假 KernelSU/kernel/ 目录。
#    接着 setup-ksu.sh 看到 KernelSU/ 存在就跳过官方 setup.sh，
#    随即因为没有 .git 而失败。
#
#    首次冷跑不会暴露（无缓存），第二次起必挂。
is_build_mount_point() {
    case "${1#./}" in
        drivers/kernelsu|drivers/kernelsu/*) return 0 ;;
    esac
    return 1
}

# --- A. 悬空的真 symlink ---
while IFS= read -r -d '' f; do
    # -e 跟随链接：目标存在就是正常链接，跳过。
    # 这一条把内核自带的仓库内链接全部排除掉。
    [ -e "$f" ] && continue

    if is_build_mount_point "$f"; then
        skip "  跳过构建挂载点: ${f#./} -> $(readlink "$f")"
        continue
    fi

    target="$(readlink "$f")"
    [ -n "$target" ] || continue

    BROKEN_PATHS+=("${f#./}")
    BROKEN_TARGETS+=("$target")
done < <(find . -type l -not -path './.git/*' -not -path './out/*' -print0)

# --- B. 退化成纯文本的 symlink ---
while IFS= read -r -d '' f; do
    # 真 symlink 已在上一轮处理过
    [ -L "$f" ] && continue

    is_build_mount_point "$f" && continue

    content="$(tr -d '\r\n' < "$f")"

    case "$content" in
        ../*) : ;;
        *) continue ;;
    esac
    case "$content" in
        *[[:space:]]*) continue ;;
    esac

    dir="$(dirname "$f")"
    # 目标能解析到实际存在的东西，说明这不是断链
    [ -e "$dir/$content" ] && continue

    BROKEN_PATHS+=("${f#./}")
    BROKEN_TARGETS+=("$content")
done < <(find . -type f -size -200c \
              -not -path './.git/*' -not -path './out/*' -print0)

if [ ${#BROKEN_PATHS[@]} -eq 0 ]; then
    ok "未发现断裂的符号链接 —— 源码完好，无需生成占位"
    exit 0
fi

log "发现 ${#BROKEN_PATHS[@]} 处断链："
for i in "${!BROKEN_PATHS[@]}"; do
    printf '    %-45s -> %s\n' "${BROKEN_PATHS[$i]}" "${BROKEN_TARGETS[$i]}"
done

# -----------------------------------------------------------------------------
# 第 2 步：判断每处断链是否真的影响编译
#
# 只有被 Makefile / Kconfig / #include 引用到的才会拖垮编译。
# 没人引用的（如 realme 源码里的 sa_common_struct.h）只需防御性处理。
# -----------------------------------------------------------------------------

is_referenced() {
    local path="$1"
    local base; base="$(basename "$path")"
    local obj="${base%.c}.o"

    # 被 #include 引用
    grep -rqs --include='*.c' --include='*.h' "[\"<]${base}[\">]" . && return 0
    # 被 obj-* 规则引用（.c → .o）
    [ "$base" != "$obj" ] && grep -rqs --include='Makefile' "\\b${obj}\\b" . && return 0
    # 目录型：被 obj-* 或 source 引用
    grep -rqs --include='Makefile' "${path}/" . && return 0
    grep -rqs --include='Kconfig*' "${path}/" . && return 0
    return 1
}

# -----------------------------------------------------------------------------
# 第 3 步：生成占位内容
# -----------------------------------------------------------------------------

section "生成占位实现"

# 从断链文件所在目录解析出目标的绝对路径（可能在 KERNEL_DIR 之外，
# 比如 ../../vendor/... 会落到 WORKSPACE 下）
resolve_target() {
    local link_path="$1" target="$2"
    local dir; dir="$(cd "$(dirname "$link_path")" && pwd)"
    # 用 realpath -m 允许路径不存在
    realpath -m "$dir/$target"
}

# 生成目录型占位：一个带空 Kconfig 和空 Makefile 的目录。
# 空 Kconfig 让 `source` 不报错，空 Makefile 让 `obj-y += dir/` 不报错。
make_dir_stub() {
    local link_path="$1" abs_target="$2" label="$3"

    mkdir -p "$abs_target"
    [ -f "$abs_target/Kconfig" ]  || : > "$abs_target/Kconfig"
    [ -f "$abs_target/Makefile" ] || : > "$abs_target/Makefile"

    # 断链文件本身是普通文件，得先删掉才能建同名目录
    if [ ! -d "$link_path" ]; then
        rm -f "$link_path"
        mkdir -p "$link_path"
        : > "$link_path/Kconfig"
        : > "$link_path/Makefile"
    fi
    ok "  目录占位: $label"
}

# oplus 的锁竞争监控 hook。
# 这些函数被主线 locking/ 与 sched/core.c 硬调用（非 tracepoint），
# 缺了会在链接期报 undefined symbol。签名从调用点逐个抄出来：
#   kernel/locking/mutex.c:48-49
#   kernel/locking/percpu-rwsem.c:16-17
#   kernel/locking/rtmutex.c:36
#   kernel/locking/rtmutex_api.c:11
#   kernel/locking/rwsem.c:37-38
#   kernel/sched/core.c:6970  locking_record_switch_in_cs()
write_oplus_locking_h() {
    cat > "$1" <<'EOF'
/* SPDX-License-Identifier: GPL-2.0 */
/*
 * oplus 锁监控 hook 的空实现（占位）。
 *
 * 官方源码 zip 丢失了 vendor/oplus/kernel/synchronize/，
 * 由 scripts/prepare-vendor-stubs.sh 自动生成本文件。
 * 这些 hook 只用于厂商的锁竞争统计，不参与任何功能逻辑，
 * 置空不影响内核行为。
 */
#ifndef _OPLUS_LOCKING_H
#define _OPLUS_LOCKING_H

struct task_struct;

static inline void locking_record_switch_in_cs(struct task_struct *task) { }

#endif /* _OPLUS_LOCKING_H */
EOF
}

write_oplus_locking_c() {
    cat > "$1" <<'EOF'
// SPDX-License-Identifier: GPL-2.0
/*
 * oplus 锁监控 hook 的空实现（占位）。
 *
 * 由 scripts/prepare-vendor-stubs.sh 自动生成。
 * 函数签名逐个抄自内核内部的 extern 声明处，改动这里前先核对：
 *   kernel/locking/mutex.c        mutex_lock_handler / mutex_wait_handler
 *   kernel/locking/percpu-rwsem.c android_vh_pcpu_rwsem_handler / pcp_wait_handler
 *   kernel/locking/rtmutex.c      rtmutex_wait_handler
 *   kernel/locking/rtmutex_api.c  rtmutex_lock_handler
 *   kernel/locking/rwsem.c        rwsem_lock_handler / rwsem_read_wait_handler
 */
#include <linux/export.h>
#include <linux/types.h>

#include "oplus_locking.h"

struct mutex;
struct percpu_rw_semaphore;
struct rt_mutex_base;
struct rw_semaphore;
struct task_struct;

void android_vh_pcpu_rwsem_handler(u64 sem, struct task_struct *tsk,
				   unsigned long jiffies) { }
EXPORT_SYMBOL_GPL(android_vh_pcpu_rwsem_handler);

void mutex_lock_handler(u64 lock, struct task_struct *tsk,
			unsigned long jiffies) { }
EXPORT_SYMBOL_GPL(mutex_lock_handler);

void mutex_wait_handler(struct mutex *lock) { }
EXPORT_SYMBOL_GPL(mutex_wait_handler);

void rwsem_lock_handler(u64 sem, struct task_struct *tsk,
			unsigned long jiffies) { }
EXPORT_SYMBOL_GPL(rwsem_lock_handler);

void rwsem_read_wait_handler(struct rw_semaphore *sem) { }
EXPORT_SYMBOL_GPL(rwsem_read_wait_handler);

void pcp_wait_handler(struct percpu_rw_semaphore *sem, bool is_reader,
		      int phase) { }
EXPORT_SYMBOL_GPL(pcp_wait_handler);

void rtmutex_lock_handler(u64 lock, struct task_struct *tsk,
			  unsigned long jiffies) { }
EXPORT_SYMBOL_GPL(rtmutex_lock_handler);

void rtmutex_wait_handler(struct rt_mutex_base *lock) { }
EXPORT_SYMBOL_GPL(rtmutex_wait_handler);
EOF
}

# oplus 的内存回收 trace 宏。被 mm/vmscan.c:8298,8505,8511 使用。
write_oplus_mm_trace_h() {
    cat > "$1" <<'EOF'
/* SPDX-License-Identifier: GPL-2.0 */
/*
 * oplus mm trace 宏的空实现（占位）。
 *
 * 由 scripts/prepare-vendor-stubs.sh 自动生成。
 * 使用点：mm/vmscan.c 的 kswapd 与直接回收路径，纯统计用途。
 */
#ifndef _OPLUS_MM_TRACE_H
#define _OPLUS_MM_TRACE_H

#define mm_trace_int64(name, value)	do { } while (0)
#define mm_trace_fmt_begin(fmt, ...)	do { } while (0)
#define mm_trace_fmt_end()		do { } while (0)

#endif /* _OPLUS_MM_TRACE_H */
EOF
}

# sched_assist 的结构体定义。realme 源码里没人 include 它，
# 但其他机型可能会，给个空头文件兜底。
write_generic_stub_h() {
    local guard
    guard="_STUB_$(basename "$1" | tr 'a-z.-' 'A-Z__')"
    cat > "$1" <<EOF
/* SPDX-License-Identifier: GPL-2.0 */
/*
 * 占位头文件，由 scripts/prepare-vendor-stubs.sh 自动生成。
 * 原符号链接目标缺失，且全树未发现引用点。
 */
#ifndef ${guard}
#define ${guard}
#endif /* ${guard} */
EOF
}

# -----------------------------------------------------------------------------
# 第 4 步：逐个处理
# -----------------------------------------------------------------------------

HANDLED=0
UNKNOWN=0

for i in "${!BROKEN_PATHS[@]}"; do
    link_path="${BROKEN_PATHS[$i]}"
    target="${BROKEN_TARGETS[$i]}"
    abs_target="$(resolve_target "$link_path" "$target")"
    base="$(basename "$link_path")"

    if is_referenced "$link_path"; then
        ref_note="被引用"
    else
        ref_note="未被引用（防御性处理）"
    fi

    case "$base" in
    # --- 目录型（无扩展名，且目标路径不像文件）---------------------------
    oplus_resctrl|storage|oplus_cpu|include)
        make_dir_stub "$link_path" "$abs_target" "$link_path （$ref_note）"
        HANDLED=$((HANDLED + 1))
        ;;

    # --- oplus locking ---------------------------------------------------
    oplus_locking.h|locking_main.h)
        mkdir -p "$(dirname "$abs_target")"
        write_oplus_locking_h "$abs_target"
        rm -f "$link_path"
        write_oplus_locking_h "$link_path"
        ok "  头文件占位: $link_path （$ref_note）"
        HANDLED=$((HANDLED + 1))
        ;;

    oplus_locking.c)
        mkdir -p "$(dirname "$abs_target")"
        write_oplus_locking_c "$abs_target"
        # oplus_locking.c 会 #include "oplus_locking.h"，
        # 而 kernel/locking/ 下只有 locking_main.h 这一个链接，
        # 所以要在同目录额外放一份同名头文件
        write_oplus_locking_h "$(dirname "$link_path")/oplus_locking.h"
        rm -f "$link_path"
        write_oplus_locking_c "$link_path"
        ok "  源文件占位: $link_path （$ref_note）"
        HANDLED=$((HANDLED + 1))
        ;;

    # --- oplus mm trace --------------------------------------------------
    mm-trace.h)
        mkdir -p "$(dirname "$abs_target")"
        write_oplus_mm_trace_h "$abs_target"
        rm -f "$link_path"
        write_oplus_mm_trace_h "$link_path"
        ok "  头文件占位: $link_path （$ref_note）"
        HANDLED=$((HANDLED + 1))
        ;;

    # --- 未知的 .h：给空头文件 -------------------------------------------
    *.h)
        mkdir -p "$(dirname "$abs_target")"
        write_generic_stub_h "$abs_target"
        rm -f "$link_path"
        write_generic_stub_h "$link_path"
        if is_referenced "$link_path"; then
            warn "  未知头文件 $link_path 被引用，已生成空占位。"
            warn "    若编译报缺符号，需在本脚本中补上对应实现。"
            UNKNOWN=$((UNKNOWN + 1))
        else
            ok "  空头文件占位: $link_path （$ref_note）"
            HANDLED=$((HANDLED + 1))
        fi
        ;;

    # --- 未知的 .c：不能瞎猜，被引用就直接失败 ---------------------------
    *.c)
        if is_referenced "$link_path"; then
            die "未知的断链源文件 $link_path -> $target，且被 Makefile 引用。
     无法自动生成实现（不知道需要哪些符号）。
     请在 scripts/prepare-vendor-stubs.sh 中为它补一个 write_*_c 分支，
     函数签名可以从内核里的 extern 声明抄。"
        fi
        rm -f "$link_path"
        : > "$link_path"
        warn "  空源文件占位: $link_path （未被引用）"
        UNKNOWN=$((UNKNOWN + 1))
        ;;

    # --- 其余：按目录处理 -------------------------------------------------
    *)
        make_dir_stub "$link_path" "$abs_target" "$link_path （$ref_note，按目录处理）"
        UNKNOWN=$((UNKNOWN + 1))
        ;;
    esac
done

# -----------------------------------------------------------------------------
# 第 5 步：复检
# -----------------------------------------------------------------------------

section "复检"

REMAIN=0
for i in "${!BROKEN_PATHS[@]}"; do
    link_path="${BROKEN_PATHS[$i]}"
    if [ -f "$link_path" ] && [ "$(stat -c%s "$link_path")" -lt 200 ]; then
        content="$(tr -d '\r\n' < "$link_path")"
        dir="$(dirname "$link_path")"
        case "$content" in
            ../*) [ -e "$dir/$content" ] || {
                    warn "  仍是断链: $link_path"; REMAIN=$((REMAIN + 1)); } ;;
        esac
    fi
done

[ "$REMAIN" -eq 0 ] || die "仍有 $REMAIN 处断链未处理"

ok "vendor 占位生成完成：${HANDLED} 处已知，${UNKNOWN} 处走了通用兜底"
[ "$UNKNOWN" -gt 0 ] && warn "有 $UNKNOWN 处走了通用兜底，若编译失败请优先看它们" || true
