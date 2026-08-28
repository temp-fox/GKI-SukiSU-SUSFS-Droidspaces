# 排查手册

按「症状 → 原因 → 处理」组织。先确定你处在哪个阶段：

- 构建阶段失败 → 看 [构建期问题](#构建期问题)
- 构建成功但刷不进去 → 看 [刷机问题](#刷机问题)
- 刷进去了但开不了机 → 看 [开机问题](#开机问题)
- 开机正常但功能不对 → 看 [功能问题](#功能问题)

---

## 构建期问题

### 编译报「找不到 vendor/ 下的文件」

```
kernel/locking/oplus_locking.c:1:1: error: expected identifier or '('
    ../../../vendor/oplus/kernel/synchronize/oplus_locking.c
```

**原因**：源码里的符号链接指向仓库外，GitHub 打 zip 时不跟随，
解压后 symlink 退化成「内容是目标路径的文本文件」，编译器把这行路径
当成 C 代码在读。

**处理**：设备配置里设 `NEEDS_VENDOR_STUBS="true"`。

若脚本报「未知的断链源文件，且被 Makefile 引用」，说明遇到了没见过的文件。
需要在 `scripts/prepare-vendor-stubs.sh` 里加一个生成函数。找出需要哪些符号：

```bash
# 在内核源码里搜这个文件对应的 extern 声明
grep -rn "extern.*your_function" kernel/ drivers/
```

把签名一字不差地抄进空实现里，加上 `EXPORT_SYMBOL_GPL`。

---

### SUSFS 主补丁产生 .rej

**先看是哪个文件冲突**。下载 `patch-rejects` 产物，看 `index.txt`。

#### 若是 `fs/proc/base.c`

多半是 include 上下文差异。同一个 6.1 LTS 系列里，不同 sublevel 的
头文件包含顺序会变，导致补丁的头部 hunk 对不上。

处理：编辑 `scripts/setup-susfs.sh`，在「第 3 节 上下文适配」里
为你的 sublevel 加一条规则。参考已有的：

```bash
if [ "$SUB" -le 141 ] && ! grep -qF '#include <linux/dma-buf.h>' fs/proc/base.c; then
    sed -i '/^#include <linux\/cpufreq_times.h>$/a #include <linux/dma-buf.h>' fs/proc/base.c
    TEMP_EDITS+=("base_dmabuf")
fi
```

记得在「第 5 节 还原临时上下文」里加对应的还原分支。

#### 若冲突面很广（十几个文件）

多半是 SUSFS 分支选错了。检查 `ANDROID_VERSION` 和 `KERNEL_VERSION`
是否与源码实际版本一致 —— 脚本会拼成 `gki-<android>-<kernel>` 去找分支。

---

### kABI 槽位被占用

```
[x] kABI 槽位 2 3 已被占用（见上面的清单）。
```

**这是保护你的，不是阻碍。** 强行用被占用的槽位会造出一个必然 bootloop 的内核。

看错误信息上方打印的槽位清单，挑三个连续的 `RESERVE`：

```
     1556:   ANDROID_KABI_USE(1, unsigned int saved_state);   ← 占用
     1558:   ANDROID_KABI_USE(2, unsigned long sched_prop);   ← 占用
     1559:   ANDROID_KABI_USE(3, ...);                        ← 占用
     1564:   ANDROID_KABI_RESERVE(4);                         ← 空闲
     1565:   ANDROID_KABI_RESERVE(5);                         ← 空闲
     1566:   ANDROID_KABI_RESERVE(6);                         ← 空闲
     1567:   ANDROID_KABI_RESERVE(7);                         ← 空闲
     1568:   ANDROID_KABI_RESERVE(8);                         ← 空闲
```

这个例子里只有 `6_7_8` 可用（4/5/6 也连续，但 `4_5_6` 不是脚本支持的
预设选项之一，需要手工改设备配置的 `DEFAULT_KABI_SLOTS`）。

改 workflow 的 `kabi_slots` 输入，或改设备配置的 `DEFAULT_KABI_SLOTS`。

---

### kABI 注入失败：找不到连续的三行 RESERVE

```
[x] kABI 改动 2 失败：未找到连续的三行
```

槽位在源码里被 `#ifdef` 隔开了。比如：

```c
	ANDROID_KABI_RESERVE(4);
	ANDROID_KABI_RESERVE(5);
#ifdef SOMETHING
	ANDROID_KABI_RESERVE(6);
#endif
	ANDROID_KABI_RESERVE(7);
```

这时 `4_5_6` 和 `6_7_8` 都不连续。挑一组真正连续的，或者手工改
`include/linux/sched.h` 把它们整理成连续的。

---

### KSU_VERSION 太低

```
[x] KSU_VERSION=13000 低于管理器最低要求 32513
```

`13000` 是 SukiSU Makefile 的兜底值，出现它说明 commit 计数失败了。

三种可能：

1. **`KernelSU/.git` 被删了** —— Makefile 靠它算 commit 数。
   检查有没有步骤执行了 `rm -rf KernelSU/.git`。
2. **浅克隆** —— `git rev-list --count` 只数到很小的值。
   脚本里已有 `git fetch --unshallow` 处理，若仍失败看网络。
3. **`main` ref 不可达** —— Makefile 写死了数 `main` 分支。

应急办法：用 `ksu_version_override` 手工指定。
但要注意这个值必须与你要用的管理器 APK 的 versionCode 一致，
否则照样报版本不匹配。

---

### zram 导致构建失败

```
ERROR: 声明的模块 drivers/block/zram/zram.ko 未产出
```

zram 改成内建后不再产出 `.ko`，但 `modules.bzl` 里还列着它。

脚本里已有自动清理逻辑。若仍失败，手工检查：

```bash
grep -n 'zram\.ko\|zsmalloc\.ko' kernel_workspace/common/modules.bzl
```

---

## 刷机问题

### AnyKernel3 报「设备不匹配」

AnyKernel3 的 `anykernel.sh` 里有设备名校验。GKI 通用包一般不校验，
但如果你换了 AnyKernel3 分支可能会。

解压 zip，编辑 `anykernel.sh`，把 `device.name1=` 那几行清空。

### boot.img 刷不进去

优先用 AnyKernel3 包。boot.img 需要：

- 与你的槽位（A/B）匹配
- AVB 签名与设备状态匹配（已解锁的设备通常不校验）

```bash
fastboot flash boot_a <你的>_boot.img
fastboot flash boot_b <你的>_boot.img
```

---

## 开机问题

### 刷完直接 bootloop，无法进系统

**最可能是 kABI 槽位问题。**

kABI 槽位选错时，厂商预编译模块（GPU / Camera）读到的是错位的
`task_struct` 成员，行为完全不可预测，通常表现为开机早期崩溃。

特征：编译期完全正常，没有任何警告，刷进去就循环重启。

处理：
1. 先刷回备份的 boot 分区
2. 看构建日志里的槽位清单，换一组槽位重新构建
3. 若换了槽位还是 bootloop，试试关掉 `enable_droidspaces` 构建一个版本 ——
   能开机就说明确实是 Droidspaces 相关；还是不行就是别的问题

### 开机 panic，日志里有 oplus_bsp_midas

```
Unable to handle kernel NULL pointer dereference
...
oplus_bsp_midas
```

设备配置里没开 `NEEDS_OPLUS_MIDAS_FIX`。

这个模块调用 `find_task_by_vpid()` 后不判空。开了 PID namespace 之后
大量进程在独立 namespace 中，它会频繁查不到 → 空指针解引用。

```bash
NEEDS_OPLUS_MIDAS_FIX="true"
```

### 开机后某些硬件不工作（相机 / 指纹 / WiFi）

厂商模块因为 CRC 校验失败没加载上。检查 `dmesg`：

```bash
dmesg | grep -i "disagrees about version"
```

如果看到大量这类信息但后面跟着 `But ignore...`，说明 CRC 放宽生效了，
问题在别处。如果没有 `But ignore...`，说明 CRC 放宽没应用上。

---

## 功能问题

### `ksud susfs version` 返回 `unsupport`

**SUSFS 的 reboot 命令通道没打通。**

SUSFS 通过 `reboot(2)` 系统调用 + 双 magic（`0xDEADBEEF` / `0xFAFAFAFA`）
与内核通信。如果内核侧没有对应的处理逻辑，这个调用会落到真正的
`SYSCALL_DEFINE4(reboot)`，因 magic 不匹配返回 `-EINVAL`，
ksud 拿到空 buffer 就报 `unsupport`。

检查顺序：

```bash
# 1. 配置项是否真的进了内核
zcat /proc/config.gz | grep KSU_SUSFS
# 应有 CONFIG_KSU_SUSFS=y

# 2. 内核里有没有 susfs 初始化
dmesg | grep -i susfs
# 应有 susfs_init 或类似输出
```

如果 `CONFIG_KSU_SUSFS` 不是 `y`：构建时的配置自检本应拦下这种情况，
检查是不是跳过了 `verify-config.sh`。

如果配置是 `y` 但 `dmesg` 没输出：多半是用了不含 SUSFS 的 SukiSU 分支。
确认 `ksu_ref` 是 `builtin` 而不是 `main`。

> 这正是本项目要解决的核心问题。SukiSU 的 `main` 分支内核侧对 SUSFS
> 是零支持 —— 在它上面手工搭适配层很容易漏掉命令通道的调用点，
> 症状就是这个。用 `builtin` 分支，通道由上游原生提供。

---

### 管理器 SUSFS 页面卡死

**这是上面那个问题的表现形式。**

管理器的设置页把阻塞式 root shell 调用直接放在 Composable 里，
没有 `remember`、没有协程。每次界面重组都会同步执行一次
`ksud susfs status`。内核侧不响应时这个调用会一直等，UI 线程被占死。

内核侧修好后，命令能秒回，症状自然消失。

如果 `ksud susfs version` 已经能正常返回版本号但页面仍然卡，
那是管理器 App 自身的问题，与内核无关 —— 换个管理器版本试试。

---

### 管理器报 `susfs_binary_not_found`

**内核侧是好的，问题在管理器的 assets。**

管理器内置的 `ksu_susfs_<版本>` 二进制只有有限几个版本。内核上报的
版本不在这个范围内时，管理器找不到对应二进制。

确认内核侧正常：

```bash
su -c 'ksud susfs version'    # 能返回 vX.Y.Z 就说明内核没问题
```

三个应对办法：

1. **用同期的管理器 APK**（推荐）—— SukiSU 的 CI 会同步更新 assets
2. **钉死 SUSFS 版本** —— 用 `susfs_ref` 输入项指定一个管理器支持的 commit
3. **改用 susfs4ksu-module** —— 独立的 Magisk 模块，运行时向内核问版本
   ⚠️ 与 ksud 自带的 `susfs_manager` 功能重叠，不能同时启用

---

### 管理器报「版本不匹配」

管理器有三条独立的校验路径，任一不过就报这个：

1. `KSU_VERSION < 32513`
2. `KSU_VERSION_FULL` 语义版本 < `v4.0.0`
3. 内核 UAPI 版本 ≠ 管理器 UAPI 版本

看构建日志里的实际值：

```
[+] KSU_VERSION      = 40823
[+] KSU_VERSION_FULL = v4.1.3-6c5603f0@builtin
```

第 1、2 条脚本在构建期已经断言过。所以刷完机还报，多半是第 3 条 ——
换与本次构建同期的管理器 APK。

或者反过来：用 `ksu_version_override` 把内核版本号钉到你手上那个
管理器 APK 的 versionCode。

---

### `droidspaces --check` 仍显示缺功能

对照构建日志里 `verify-config.sh` 的输出。那一步会逐项检查
`out/.config`，理论上不该放过任何缺失。

如果自检通过了但设备上仍缺，可能是：

- **刷的不是刚构建的内核** —— `uname -a` 对一下版本串和时间戳
- **A/B 槽位刷错了** —— 检查 `getprop ro.boot.slot_suffix`，
  确认刷的是当前活动槽位

---

### 容器内网络不通

需要开 `enable_network_ext`。基础容器不需要它，但 Docker 的 NAT、
UFW 的规则、fail2ban 的限速都依赖这些 netfilter 扩展。

验证：

```bash
# 容器内
iptables -m addrtype --help    # 不报错说明 ADDRTYPE 匹配可用
ipset --version                # ipset 可用
```

---

## 通用排查手法

### 确认刷进去的确实是刚构建的内核

```bash
uname -a
```

对照 `build-info.txt` 里的「版本串」一行。不一致说明刷错了包或刷错了槽位。

### 看内核实际的配置

```bash
zcat /proc/config.gz | grep <你关心的配置项>
```

若 `/proc/config.gz` 不存在，说明 `CONFIG_IKCONFIG_PROC` 没开，
这时只能对照构建日志。

### 从构建产物里读配置

构建失败时会上传 `diagnostics` 产物，里面有：

- `final.config` —— 最终生效的完整配置
- `defconfig.diff` —— 我们相对原厂 defconfig 改了什么
- `sched_h_kabi.txt` —— kABI 注入的实际结果
- `rej-list.txt` —— 所有补丁冲突文件的清单

排查 bootloop 时 `sched_h_kabi.txt` 最有用。

---

## 还是解决不了

开 issue 时请附上：

1. 设备型号 + 固件版本 + `uname -a` 输出
2. 用了哪些构建选项
3. 完整的构建日志（Actions 页面右上角可以下载）
4. 如果有 `diagnostics` 或 `patch-rejects` 产物，一并附上
5. 设备上的相关输出（`dmesg | grep -i susfs`、`droidspaces --check` 等）

信息越全，越容易定位。只说「不能用」的话，只能从头猜。
