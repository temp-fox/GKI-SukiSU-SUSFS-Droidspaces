#!/usr/bin/env bash
# 应用 SUSFS 内核补丁。
#
# 【工作方式】
# SUSFS 由两部分组成：
#   1. 内核侧文件（fs/susfs.c、include/linux/susfs*.h）—— 直接复制
#   2. 主补丁 50_add_susfs_in_gki-<android>-<kernel>.patch —— 往内核各处插 hook
#
# builtin 分支的 SukiSU 已经自带 KSU 侧的 SUSFS 支持，
# 所以不打 kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch（会冲突）。
#
# 【上下文适配】
# 主补丁是按某个特定 sublevel 的源码生成的。同一 LTS 系列内不同 sublevel
# 的头文件包含顺序会有差异，导致补丁的头部 hunk 失配 —— 表现是编译时报
# 「susfs_def.h 里的宏未定义」，而不是打补丁时就失败。
#
# 处理方式沿用上游 GKI_KernelSU_SUSFS 的思路：打补丁前临时插入缺失的
# include 让上下文对齐，打完再还原。这样源码里不会留下无关差异。
#
# 输出到 $GITHUB_ENV：
#   SUSFS_VERSION / SUSFS_SHA / SUSFS_DATE

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_env WORKSPACE ANDROID_VERSION KERNEL_VERSION
KERNEL_DIR="${KERNEL_DIR:-$WORKSPACE/common}"
SUB="${ACTUAL_SUBLEVEL:-${KERNEL_SUBLEVEL:-0}}"
[[ "$SUB" =~ ^[0-9]+$ ]] || SUB=99999

cd "$WORKSPACE"

section "集成 SUSFS"

# -----------------------------------------------------------------------------
# 1. 拉取 susfs4ksu
# -----------------------------------------------------------------------------

SUSFS_BRANCH="gki-${ANDROID_VERSION}-${KERNEL_VERSION}"
SUSFS_REPO="${SUSFS_REPO:-https://github.com/ShirkNeko/susfs4ksu.git}"
SUSFS_FALLBACK="https://gitlab.com/simonpunk/susfs4ksu.git"

if [ -d susfs4ksu ]; then
    skip "susfs4ksu/ 已存在，跳过克隆"
else
    log "克隆 $SUSFS_REPO @ $SUSFS_BRANCH"
    if ! git clone --depth=1 -b "$SUSFS_BRANCH" "$SUSFS_REPO" susfs4ksu 2>/dev/null; then
        warn "主源没有分支 $SUSFS_BRANCH，回退到上游 simonpunk"
        git clone --depth=1 -b "$SUSFS_BRANCH" "$SUSFS_FALLBACK" susfs4ksu \
            || die "无法获取 SUSFS 补丁（分支 $SUSFS_BRANCH 在两个源都不存在）。
     确认 ANDROID_VERSION=$ANDROID_VERSION 与 KERNEL_VERSION=$KERNEL_VERSION 是否正确。"
    fi
fi

# 可选：钉死到特定 commit，用于复现历史构建或规避上游回归
if [ -n "${SUSFS_REF:-}" ]; then
    log "切换到指定 commit: $SUSFS_REF"
    ( cd susfs4ksu
      git fetch --depth=1 origin "$SUSFS_REF" 2>/dev/null || git fetch origin
      git checkout "$SUSFS_REF" ) || die "无法切换到 SUSFS commit $SUSFS_REF"
fi

SUSFS_SHA="$(git -C susfs4ksu rev-parse --short=8 HEAD)"
SUSFS_DATE="$(git -C susfs4ksu log -1 --date=format:'%Y-%m-%d %H:%M:%S' --format='%cd')"
ok "susfs4ksu: $SUSFS_SHA （最后提交 $SUSFS_DATE）"

# -----------------------------------------------------------------------------
# 2. 复制内核侧文件
# -----------------------------------------------------------------------------

section "复制 SUSFS 内核文件"

PATCH_DIR="$WORKSPACE/susfs4ksu/kernel_patches"
require_dir "$PATCH_DIR" "susfs4ksu 补丁目录"

require_dir "$PATCH_DIR/fs"
cp -v "$PATCH_DIR"/fs/* "$KERNEL_DIR/fs/"

require_dir "$PATCH_DIR/include/linux"
cp -v "$PATCH_DIR"/include/linux/* "$KERNEL_DIR/include/linux/"

# 读取 SUSFS 版本 —— 这个值决定管理器要释放哪个二进制，很重要
SUSFS_H="$KERNEL_DIR/include/linux/susfs.h"
require_file "$SUSFS_H" "susfs.h"
SUSFS_VERSION="$(grep -m1 '^#define SUSFS_VERSION' "$SUSFS_H" | cut -d'"' -f2)"
[ -n "$SUSFS_VERSION" ] || die "无法从 susfs.h 解析 SUSFS_VERSION"
ok "SUSFS 版本: $SUSFS_VERSION"

# -----------------------------------------------------------------------------
# 3. 上下文适配（打补丁前）
#
# 只处理确实需要的组合。每处都先检查「是否已经有」，避免重复插入。
# -----------------------------------------------------------------------------

section "适配补丁上下文"

cd "$KERNEL_DIR"
MAIN_PATCH="$PATCH_DIR/50_add_susfs_in_gki-${ANDROID_VERSION}-${KERNEL_VERSION}.patch"
require_file "$MAIN_PATCH" "SUSFS 主补丁"

# 记录做了哪些临时改动，打完���丁后按记录还原
declare -a TEMP_EDITS=()

# 补丁用了 VMA_PAD_START，但部分 LTS 分支没有这个宏
if grep -qF 'VMA_PAD_START(vma)' "$MAIN_PATCH" \
   && ! grep -Rqs 'VMA_PAD_START' ./include/linux; then
    log "目标内核无 VMA_PAD_START，改用 vma->vm_end"
    # 改补丁副本而不是原件，避免污染 susfs4ksu 工作树
    cp "$MAIN_PATCH" ./susfs_main.patch
    sed -i 's/VMA_PAD_START(vma)/vma->vm_end/g' ./susfs_main.patch
    MAIN_PATCH="$KERNEL_DIR/susfs_main.patch"
fi

if [ "$ANDROID_VERSION" = "android14" ] && [ "$KERNEL_VERSION" = "6.1" ]; then
    # 6.1 sublevel <= 141：补丁的 fs/proc/base.c 头部 hunk 期望有 dma-buf.h，
    # 而这些版本的源码里还没有。本机 sublevel 115 命中这一条。
    if [ "$SUB" -le 141 ] && ! grep -qF '#include <linux/dma-buf.h>' fs/proc/base.c; then
        log "临时插入 fs/proc/base.c 的 dma-buf.h（sublevel $SUB <= 141）"
        sed -i '/^#include <linux\/cpufreq_times.h>$/a #include <linux/dma-buf.h>' fs/proc/base.c
        assert_contains fs/proc/base.c '#include <linux/dma-buf.h>' "临时插入 dma-buf.h"
        TEMP_EDITS+=("base_dmabuf")
    fi

    # 6.1 sublevel <= 25：期望有 trace/hooks/sched.h
    if [ "$SUB" -le 25 ] && ! grep -qF '#include <trace/hooks/sched.h>' fs/proc/base.c; then
        log "临时插入 fs/proc/base.c 的 trace/hooks/sched.h（sublevel $SUB <= 25）"
        sed -i '/^#include <trace\/events\/oom.h>$/a #include <trace/hooks/sched.h>' fs/proc/base.c
        TEMP_EDITS+=("base_sched")
    fi

    # 6.1 sublevel >= 157：新增了 trace/hooks/blk.h，补丁上下文里没有
    if [ "$SUB" -ge 157 ] && grep -qF '#include <trace/hooks/blk.h>' fs/namespace.c; then
        log "临时移除 fs/namespace.c 的 trace/hooks/blk.h（sublevel $SUB >= 157）"
        sed -i '/^#include <trace\/hooks\/blk.h>$/d' fs/namespace.c
        TEMP_EDITS+=("namespace_blk")
    fi
fi

if [ "$ANDROID_VERSION" = "android15" ] && [ "$KERNEL_VERSION" = "6.6" ]; then
    if [ "$SUB" -le 92 ] && ! grep -qF '#include <linux/dma-buf.h>' fs/proc/base.c; then
        sed -i '/^#include <linux\/cpufreq_times.h>$/a #include <linux/dma-buf.h>' fs/proc/base.c
        TEMP_EDITS+=("base_dmabuf")
    fi
    if [ "$SUB" -le 57 ] && ! grep -qF '#include <linux/zswap.h>' mm/memory.c; then
        sed -i '/^#include <linux\/sched\/sysctl.h>$/a #include <linux/zswap.h>' mm/memory.c
        TEMP_EDITS+=("memory_zswap")
    fi
fi

if [ "$ANDROID_VERSION" = "android16" ] && [ "$KERNEL_VERSION" = "6.12" ]; then
    if [ "$SUB" -ge 58 ] && grep -qF '#include <linux/dma-buf.h>' fs/exec.c; then
        sed -i '/^#include <linux\/dma-buf.h>$/d' fs/exec.c
        TEMP_EDITS+=("exec_dmabuf")
    fi
fi

[ ${#TEMP_EDITS[@]} -eq 0 ] && ok "无需上下文适配" \
    || log "做了 ${#TEMP_EDITS[@]} 处临时调整，打完补丁会还原"

# -----------------------------------------------------------------------------
# 4. 应用主补丁
#
# ⚠️ 不加 || true。SUSFS 补丁失败 = SUSFS 不工作 = 本项目的核心目标落空。
# -----------------------------------------------------------------------------

section "应用 SUSFS 主补丁"

if patch -p1 --dry-run --reverse --force < "$MAIN_PATCH" >/dev/null 2>&1; then
    skip "SUSFS 主补丁已应用过"
else
    if ! patch -p1 --forward --no-backup-if-mismatch < "$MAIN_PATCH"; then
        printf '\n' >&2
        find . -name '*.rej' -type f -print >&2 || true
        die "SUSFS 主补丁应用失败。

     这是本项目的核心功能，不能跳过。排查顺序：
     1. 看上面列出的 .rej 文件，确认是哪个 hunk 冲突
     2. 若是 fs/proc/base.c 的头部 hunk，多半是 include 上下文差异 ——
        看本脚本第 3 节，可能需要为当前 sublevel（$SUB）加一条适配规则
     3. 若冲突面很广，可能是 SUSFS 分支选错了
        （当前用的是 $SUSFS_BRANCH）"
    fi
fi

# 补丁能「成功」但留下 .rej —— 部分 hunk 失败时 patch 仍返回 0。
# 这类静默失败最终表现为编译期的宏未定义，很难往回追。
assert_no_rejects "$KERNEL_DIR" "SUSFS 主补丁"

# -----------------------------------------------------------------------------
# 5. 还原临时改动
# -----------------------------------------------------------------------------

section "还原临时上下文"

for edit in "${TEMP_EDITS[@]:-}"; do
    case "$edit" in
        base_dmabuf)
            sed -i '/^#include <linux\/dma-buf.h>$/d' fs/proc/base.c
            ok "  已还原 fs/proc/base.c 的 dma-buf.h" ;;
        base_sched)
            sed -i '/^#include <trace\/hooks\/sched.h>$/d' fs/proc/base.c
            ok "  已还原 fs/proc/base.c 的 trace/hooks/sched.h" ;;
        namespace_blk)
            grep -qF '#include <trace/hooks/blk.h>' fs/namespace.c \
                || sed -i '/^#include "internal.h"$/a #include <trace/hooks/blk.h>' fs/namespace.c
            ok "  已还原 fs/namespace.c 的 trace/hooks/blk.h" ;;
        memory_zswap)
            sed -i '/^#include <linux\/zswap.h>$/d' mm/memory.c
            ok "  已还原 mm/memory.c 的 zswap.h" ;;
        exec_dmabuf)
            grep -qF '#include <linux/dma-buf.h>' fs/exec.c \
                || sed -i '0,/^#include /s//#include <linux\/dma-buf.h>\n&/' fs/exec.c
            ok "  已还原 fs/exec.c 的 dma-buf.h" ;;
    esac
done

rm -f ./susfs_main.patch

# -----------------------------------------------------------------------------
# 6. 补丁后修复
#
# 补丁的头部 hunk 若因上下文差异被跳过，宏声明就没进来，
# 而使用这些宏的 hunk 却打进去了 —— 编译时报未定义。
# 这里主动检查「用了宏但没有声明」的情况并补上。
# -----------------------------------------------------------------------------

section "补丁后一致性检查"

# fs/proc/base.c：用了 SUSFS 宏就必须有 susfs_def.h
if grep -qE 'susfs_is_current_proc_umounted|SUSFS_IS_INODE_SUS_MAP|SUSFS_IS_INODE_OPEN_REDIRECT' fs/proc/base.c \
   && ! grep -qF 'susfs_def.h' fs/proc/base.c; then
    warn "fs/proc/base.c 用了 SUSFS 宏但缺 susfs_def.h，补充声明"
    sed -i '/#include <linux\/cpufreq_times.h>/a #if defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)\n#include <linux\/susfs_def.h>\n#endif' fs/proc/base.c
    assert_contains fs/proc/base.c 'susfs_def.h' "补充 susfs_def.h"
fi

# fs/namespace.c：SUSFS 的 mount 隐藏需要几个 extern 声明
if grep -qE 'DEFAULT_KSU_MNT_ID|susfs_mnt_id_ida|CL_COPY_MNT_NS' fs/namespace.c; then
    if ! grep -qF '#include <linux/susfs_def.h>' fs/namespace.c; then
        warn "fs/namespace.c 缺 susfs_def.h，补充"
        if grep -qF '#include <linux/mnt_idmapping.h>' fs/namespace.c; then
            sed -i '/#include <linux\/mnt_idmapping.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux\/susfs_def.h>\n#endif' fs/namespace.c
        elif grep -qF '#include <linux/shmem_fs.h>' fs/namespace.c; then
            sed -i '/#include <linux\/shmem_fs.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux\/susfs_def.h>\n#endif' fs/namespace.c
        else
            sed -i '0,/^#include /s//#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux\/susfs_def.h>\n#endif\n&/' fs/namespace.c
        fi
    fi
    if ! grep -q 'extern bool susfs_is_current_ksu_domain' fs/namespace.c; then
        warn "fs/namespace.c 缺 SUSFS mount extern 声明，补充"
        sed -i '/#include "internal.h"/a \\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n\n#define CL_COPY_MNT_NS BIT(25)\n\n#endif' fs/namespace.c
    fi
fi

# 关键文件必须落地
require_file "$KERNEL_DIR/fs/susfs.c"       "SUSFS 核心实现"
require_file "$KERNEL_DIR/include/linux/susfs.h"
require_file "$KERNEL_DIR/include/linux/susfs_def.h"

if is_true "${ENABLE_SUSFS:-false}"; then
    ok "SUSFS 集成完成 —— 版本 $SUSFS_VERSION"
    put_env SUSFS_VERSION "$SUSFS_VERSION"
    put_env SUSFS_SHA     "$SUSFS_SHA"
    put_env SUSFS_DATE    "$SUSFS_DATE"
    put_output susfs_version "$SUSFS_VERSION"
else
    ok "SUSFS 源码支持已准备 —— 当前构建未启用 CONFIG_KSU_SUSFS"
fi

# -----------------------------------------------------------------------------
# 7. 版本兼容性提醒
#
# 管理器 assets 里只打包了有限几个 ksu_susfs_<version> 二进制。
# 内核版本超出范围时，管理器会报 susfs_binary_not_found —— 内核侧其实
# 是好的，但用户会以为构建失败。构建期提醒，省得刷完机再回头查。
# -----------------------------------------------------------------------------

if is_true "${ENABLE_SUSFS:-false}"; then
    MANAGER_MAX="2.1.0"
    SUSFS_NUM="${SUSFS_VERSION#v}"
    if [ "$(printf '%s\n%s\n' "$MANAGER_MAX" "$SUSFS_NUM" | sort -V | tail -1)" = "$SUSFS_NUM" ] \
       && [ "$SUSFS_NUM" != "$MANAGER_MAX" ]; then
        warn "SUSFS $SUSFS_VERSION 高于已知的管理器 assets 上限 v$MANAGER_MAX。"
        warn "  内核侧不受影响，但管理器 SUSFS 页面可能报 susfs_binary_not_found。"
        warn "  应对：用与本次构建同期的管理器 APK，或用 susfs_ref 钉死到旧版本。"
        warn "  详见 docs/troubleshooting.md"
    fi
fi
