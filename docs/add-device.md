# 添加新机型

核心思路：**加机型 = 加一个 `.env` 文件**。构建逻辑本身不用动。

整个过程大约 20 分钟准备 + 若干次试构建。

---

## 第一步：收集设备信息

在目标设备上（需要 root 或 adb shell）：

```bash
# 内核版本串 —— 决定 KERNEL_LOCALVERSION
uname -r
# 例：6.1.115-android14-11-o-gbc8558aaf2a5
#          └──────────┬──────────────┘
#                     这部分就是 KERNEL_LOCALVERSION

# 构建时间戳 —— 决定 FAKE_BUILD_TIME
uname -v
# 例：#1 SMP PREEMPT Wed Sep 10 13:11:53 UTC 2025
#                    └────────┬─────────────┘
#                             这部分就是 FAKE_BUILD_TIME

# 完整版本串 —— 决定 KBUILD_BUILD_USER / KBUILD_BUILD_HOST /
# KERNEL_COMPILER_STRING / EXPECTED_KERNEL_VERSION_STRING
cat /proc/version

# 主板代号
getprop ro.product.board

# 固件版本
getprop ro.build.version.incremental
```

`KERNEL_LOCALVERSION`、`FAKE_BUILD_TIME`、`KBUILD_BUILD_USER`、`KBUILD_BUILD_HOST`
和 `KERNEL_COMPILER_STRING` 只影响「产物看起来像不像原厂」，填错不影响能否开机，
但会让 `uname` / `/proc/version` 输出与原厂不一致。若已拿到原厂完整
`Linux version ...` 行，建议填入 `EXPECTED_KERNEL_VERSION_STRING`，构建脚本会用最终
Image 做严格校验。

---

## 第二步：找到内核源码

按 GPL 要求，厂商必须公开内核源码。常见位置：

| 厂商 | 地址 |
|---|---|
| OPPO / 一加 / realme | https://github.com/oplus-source 、`realme-kernel-opensource` |
| 小米 | https://github.com/MiCode/Xiaomi_Kernel_OpenSource |
| 三星 | https://opensource.samsung.com |
| 摩托罗拉 | https://github.com/MotorolaMobilityLLC |

找不到厂商源码时，也可以直接用 Google 的 ACK 通用内核
（`SOURCE_TYPE="repo-manifest"`）。缺点是没有厂商驱动，
适合纯 GKI 场景，不适合需要厂商模块的日用机型。

**确认内核版本**：看源码根目录 `Makefile` 的头几行：

```makefile
VERSION = 6
PATCHLEVEL = 1
SUBLEVEL = 115
```

再看 `build.config.constants`：

```
BRANCH=android14-6.1
```

以及 `build.config.common`：

```
KMI_GENERATION=11
```

这几个值分别对应 `KERNEL_VERSION` / `KERNEL_SUBLEVEL` / `ANDROID_VERSION` / `KMI_GENERATION`。

---

## 第三步：创建配置文件

```bash
cp devices/_template.env devices/<你的机型代号>.env
```

文件名里的机型代号必须和文件内的 `DEVICE_CODE` 一致，只用小写字母数字下划线。

最少需要填这 8 项：

```bash
DEVICE_CODE="mydevice"
DEVICE_NAME="My Phone"
SOURCE_TYPE="github-zip"
SOURCE_REPO="vendor/kernel-source-repo"
SOURCE_REF="master"
ANDROID_VERSION="android14"
KERNEL_VERSION="6.1"
KERNEL_SUBLEVEL="115"
```

模板里每一项都有注释说明，照着填即可。

---

## 第四步：把机型加进 workflow 的下拉列表

编辑 `.github/workflows/build.yml`，找到：

```yaml
      device:
        description: '目标设备（读取 devices/<设备>.env）'
        required: true
        type: choice
        default: 'rmx5062'
        options:
          - 'rmx5062'
          - 'mydevice'     # ← 加这一行
```

（GitHub Actions 的 choice 类型不支持动态选项，只能手工列。）

---

## 第五步：分阶段试构建

**不要一上来就开全部特性。** 按下面的顺序逐步加，每一步跑通再进下一步 ——
出问题时才知道是哪一步引入的。

### 阶段 1：裸内核

先关掉所有特性，只验证「源码能编译」：

```
enable_susfs        = false
enable_droidspaces  = false
enable_kpm          = false
enable_network_ext  = false
enable_rekernel     = false

# zram 是必选基础功能，workflow 固定 ENABLE_ZRAM=true，不提供关闭参数。
```

**这一步是最容易失败的**，因为厂商源码往往有各种坑。

<details>
<summary>常见失败：找不到 vendor/ 下的文件</summary>

报错形如：

```
kernel/locking/oplus_locking.c:1:1: error: expected identifier
    ../../../vendor/oplus/kernel/synchronize/oplus_locking.c
```

原因：源码里有指向仓库外的符号链接，GitHub 打 zip 时丢了目标，
解压后 symlink 退化成「内容是目标路径的纯文本文件」。

解法：在设备配置里设置

```bash
NEEDS_VENDOR_STUBS="true"
```

`scripts/prepare-vendor-stubs.sh` 会自动扫描并生成占位。

如果它报「未知的断链源文件，且被 Makefile 引用」，说明遇到了脚本没见过的
文件，需要在那个脚本里补一个生成函数。函数签名可以从内核里的 `extern`
声明抄 —— 比如 `grep -rn "extern.*your_function" kernel/`。

</details>

<details>
<summary>常见失败：某个 Kconfig 找不到</summary>

报错形如：

```
Kconfig.ext:4: can't open file "kernel/oplus_cpu/Kconfig"
```

同样是符号链接问题，同样用 `NEEDS_VENDOR_STUBS="true"` 解决。

</details>

**验收标准**：产物里有 `Image` 且大于 20 MB。

### 阶段 2：加 SukiSU

```
enable_susfs = false     # 先不开 SUSFS
```

**构建期验收**：日志里有

```
[+] KSU_VERSION      = 4xxxx
```

数字必须 ≥ 32513。低于这个值管理器会拒绝识别。

**设备验收**：刷入后打开 SukiSU 管理器，应显示「已安装」，不报版本不匹配。

### 阶段 3：加 SUSFS

```
enable_susfs = true
```

**构建期验收**：日志里有 `SUSFS 版本: vX.Y.Z`，且没有 `.rej` 冲突。

**设备验收**：

```bash
su -c 'ksud susfs version'    # 返回版本号，不能是 unsupport
su -c 'ksud susfs status'     # 返回 true
dmesg | grep -i susfs         # 有 susfs_init 输出
```

再打开管理器的 SUSFS 设置页，**不应该卡死**。

### 阶段 4：加 Droidspaces

```
enable_droidspaces = true
```

⚠️ **这一步最需要小心 kABI 槽位。**

先看构建日志开头打印的槽位占用清单：

```
[*] task_struct 的 ANDROID_KABI 槽位占用：
     1556:   ANDROID_KABI_USE(1, unsigned int saved_state);
     1558:   ANDROID_KABI_USE(2, unsigned long sched_prop);
     1559:   ANDROID_KABI_USE(3, struct sched_ext_entity *scx);
     1564:   ANDROID_KABI_RESERVE(4);
     1565:   ANDROID_KABI_RESERVE(5);
     1566:   ANDROID_KABI_RESERVE(6);
     1567:   ANDROID_KABI_RESERVE(7);
     1568:   ANDROID_KABI_RESERVE(8);
```

`USE` = 已占用，`RESERVE` = 空闲。挑**三个连续的、都是 RESERVE 的**。
上面这个例子里只有 `6_7_8` 可选。

注意 `#ifdef` 分支里的 `USE` 也算占用 —— 上例的槽 2/3 就是因为
`CONFIG_SLIM_SCHED=y` 才被占的。

槽位选错的后果：**能编译、能刷入、开机 bootloop，没有任何日志。**
这是最难排查的失败模式，所以脚本会在编译前硬失败拦下已占用的槽位。

**厂商修复**：OPPO / 一加 / realme 机型必须开

```bash
NEEDS_OPLUS_MIDAS_FIX="true"
```

否则开机会因为 `oplus_bsp_midas` 模块的空指针解引用而 panic。

**设备验收**：

```bash
droidspaces --check
# 之前显示 ✗ 的项应该全部变 ✓
# 最后一行应是 All required features found!
```

同时留意：**开机是否正常**。bootloop 就是 kABI 槽位选错了。

### 阶段 5：可选特性

一次开一个，各自验证：

| 特性 | 验证方法 |
|---|---|
| KPM | 管理器里能看到 KPM 页面 |
| 网络扩展 | 容器内 `iptables -m addrtype --help` 不报错 |
| zram | `cat /proc/swaps` 里有 zram 设备 |
| Re-Kernel | `dmesg \| grep -i rekernel` 有输出 |
| BBR | `sysctl net.ipv4.tcp_available_congestion_control` 里有 bbr |

---

## 第六步：提交

自己用的话到这里就完了。想让别人也能用：

```bash
git add devices/<你的机型>.env .github/workflows/build.yml
git commit -m "新增机型支持：<机型名>"
```

提 PR 时请附上：

- 设备型号与固件版本
- 用了哪些选项组合
- `droidspaces --check` 的实际输出
- 有没有遇到需要特殊处理的坑

---

## 高级：机型专属配置

如果你的机型需要一些别人不需要的配置项，新建一个片段文件：

```bash
# config/devices/mydevice.config
CONFIG_SOMETHING_SPECIAL=y
# CONFIG_SOMETHING_ELSE is not set
```

然后在设备配置里引用：

```bash
EXTRA_CONFIG_FRAGMENTS="config/devices/mydevice.config"
```

这个片段在所有其他配置之后应用，所以可以覆盖前面的设置。

---

## 高级：机型专属补丁

放到 `patches/vendor/<厂商>/` 下，然后在 `scripts/setup-droidspaces.sh` 或
`setup-optional.sh` 里加一段条件应用逻辑。参考现有的
`NEEDS_OPLUS_MIDAS_FIX` 写法。

写补丁时请一并写清楚：

- 为什么需要这个补丁（不打会怎样）
- 上下文是对着哪个版本的源码核实的
- 失败时的表现是什么

补丁本身是自解释的，但「为什么需要它」不写下来就会丢失。
