#!/usr/bin/env bash
# 接入 SukiSU built-in 自身必需的主内核 hook。
#
# 这一步只处理「CONFIG_KSU=y 但 CONFIG_KSU_SUSFS=n」仍然必须存在的通道，
# 不能放进 SUSFS 环节里。SUSFS 的 GKI patch 会在 CONFIG_KSU_SUSFS=y 时
# 另外接入自己的 reboot / read / exec / stat / setresuid 路径；但用户实测已经
# 证明，只开 SukiSU 时如果没有非 SUSFS 的 reboot 通道，管理器会连不到
# built-in 的 [ksu_driver] fd，表现成仍走旧 LKM。
#
# 当前 SukiSU-Ultra builtin 分支的源码证据：
#   - kernel/supercall/supercall.c 在 !CONFIG_KSU_SUSFS 下实现了
#     ksu_handle_sys_reboot()，用于 KSU_INSTALL_MAGIC2 安装 [ksu_driver] fd；
#   - 但 ksu_supercalls_init() 只 dump commands，不再注册 reboot kprobe；
#   - susfs4ksu 主补丁只在 CONFIG_KSU_SUSFS 下往 kernel/reboot.c 接这个函数。
# 因此非 SUSFS 的 built-in 构建必须由 SukiSU 环节补上这个 hook。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_env WORKSPACE
KERNEL_DIR="${KERNEL_DIR:-$WORKSPACE/common}"
KSU_REF="${KSU_REF:-builtin}"

section "接入 SukiSU built-in 主内核 hook"

if ! is_true "${ENABLE_KSU:-true}"; then
    skip "ENABLE_KSU=false，跳过 SukiSU built-in hook"
    exit 0
fi

if [ "$KSU_REF" != "builtin" ]; then
    skip "ksu_ref=$KSU_REF，不按 builtin 分支补主内核 hook"
    exit 0
fi

KSU_SUPERCALL_C="$WORKSPACE/KernelSU/kernel/supercall/supercall.c"
REBOOT_C="$KERNEL_DIR/kernel/reboot.c"

require_file "$KSU_SUPERCALL_C" "SukiSU supercall 实现"
require_file "$REBOOT_C" "内核 reboot syscall 源码"

# 先确认上游确实提供了非 SUSFS 的 reboot 处理函数。没有这个实现就不能盲目
# 往 kernel/reboot.c 写调用点，否则只是把编译错误推迟到 CI。
if ! grep -qE 'int[[:space:]]+ksu_handle_sys_reboot\([[:space:]]*int[[:space:]]+magic1,[[:space:]]*int[[:space:]]+magic2,[[:space:]]*unsigned[[:space:]]+int[[:space:]]+cmd,[[:space:]]*void[[:space:]]+__user[[:space:]]+\*\*[[:space:]]*arg[[:space:]]*\)' "$KSU_SUPERCALL_C"; then
    die "当前 SukiSU builtin 分支没有非 SUSFS ksu_handle_sys_reboot()，不能安全接入 built-in fd 安装通道。"
fi

cd "$KERNEL_DIR"

if grep -qF 'SukiSU built-in reboot hook' kernel/reboot.c; then
    skip "SukiSU built-in reboot hook 已存在"
else
    log "补充非 SUSFS built-in reboot hook"

    if grep -qF 'DEFINE_MUTEX(system_transition_mutex);' kernel/reboot.c; then
        sed -i '/DEFINE_MUTEX(system_transition_mutex);/i\
#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_SUSFS)\
/* SukiSU built-in reboot hook：安装 [ksu_driver] fd，不属于 SUSFS。 */\
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd,\
                                 void __user **arg);\
#endif\
' kernel/reboot.c
    else
        die "kernel/reboot.c 中找不到 system_transition_mutex，无法定位 extern 插入点。"
    fi

    # 放在 reboot(2) 的原厂权限检查之前。KSU_INSTALL_MAGIC2 请求本来不是要
    # 真的重启，而是借 reboot syscall 给当前进程安装匿名 [ksu_driver] fd。
    # 使用独立 ksu_ret 并把参数换行，避免被 SUSFS hook 自检误认为 SUSFS 分支已接入。
    python3 - <<'PY'
from pathlib import Path
p = Path('kernel/reboot.c')
data = p.read_text()
needle = 'SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,'
start = data.find(needle)
if start < 0:
    raise SystemExit('kernel/reboot.c 中找不到 SYSCALL_DEFINE4(reboot)')
ret_pos = data.find('int ret = 0;', start)
if ret_pos < 0:
    raise SystemExit('kernel/reboot.c 中找不到 reboot syscall 的 ret 初始化位置')
line_end = data.find('\n', ret_pos)
insert = r'''

#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_SUSFS)
	{
		int ksu_ret = ksu_handle_sys_reboot(magic1, magic2, cmd,
		                                    &arg);
		if (!ksu_ret)
			return ksu_ret;
	}
#endif'''
p.write_text(data[:line_end] + insert + data[line_end:])
PY
fi

assert_contains kernel/reboot.c 'SukiSU built-in reboot hook' "SukiSU built-in reboot hook 声明"
assert_contains kernel/reboot.c 'ksu_handle_sys_reboot(magic1, magic2, cmd,' "SukiSU built-in reboot hook 调用"
assert_contains kernel/reboot.c '!defined(CONFIG_KSU_SUSFS)' "SukiSU built-in hook 必须与 SUSFS 分支隔离"

ok "SukiSU built-in 主内核 hook 已接入"
