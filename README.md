# GKI-SukiSU-SUSFS-Droidspaces

用 GitHub Actions 编译 Android GKI 内核，核心集成 SukiSU-Ultra、SUSFS 与 Droidspaces 内核支撑，并按功能归类提供网络、zram、BBR、Re-Kernel、NTsync、BBG 等可选增强。

| 组件 | 作用 |
|---|---|
| **[SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra)** | root 方案，包含 KPM 与 builtin 分支的 SUSFS 侧支持 |
| **[SUSFS](https://github.com/ShirkNeko/susfs4ksu)** | 挂载隐藏、路径隐藏、属性伪装等 root 隐藏能力 |
| **Droidspaces 内核支撑** | Linux 容器运行时所需的 namespace / IPC / devtmpfs / kABI 修正 |
| **普通 config 增强** | zram、网络扩展、BBR 等内核已有能力的配置开启 |
| **外部源码 / 补丁增强** | Re-Kernel、NTsync、BBG 等按需拉取或应用的增强功能 |

**设备可插拔** —— 添加新机型 = 新增一个 `devices/<机型>.env` 文件，不改 workflow。

---

## 快速开始

1. Fork 本仓库
2. 打开 Actions 页面 → 左侧选「构建内核」→ 右上角 `Run workflow`
3. 选择设备，其余保持默认即可
4. 构建约 40–70 分钟（首次冷编译更久，之后有 ccache 会快很多）
5. 从 Artifacts 下载后缀为 `-AnyKernel3` 的 artifact，下载到的 zip 本身就是可刷 AK3 包，用 TWRP / KernelFlasher 刷入

> 刷之前先备份 boot 分区。

---

## 支持的设备

| 机型 | 代号 | 内核 | 状态 |
|---|---|---|---|
| realme Neo7 Turbo | `rmx5062` | 6.1.115-android14-11 | 首发支持 |

添加你的机型见 **[docs/add-device.md](docs/add-device.md)**。

---

## 输出产物说明

构建成功后，Actions 默认只上传两个 artifact：`-AnyKernel3` 与 `-build-info`。`-Image`、`-boot`、`-final-config` 属于调试/手动打包产物，只有开启 `output_debug_artifacts` 时才额外上传。

> GitHub 的 `upload-artifact` 下载时会自动把 artifact 目录打成一个 zip。也就是说，页面上下载到的 zip 是 GitHub 自动生成的外层下载包；本项目不会再额外生成一层 AK3 zip，避免 zip 套 zip。

| artifact 名称后缀 | 内容 | 是否包含本次编译后的内核 | 是否可直接刷入 | 说明 |
|---|---|---|---|---|
| `-AnyKernel3` | AnyKernel3 刷机包目录内容：`anykernel.sh`、AK3 脚本文件、本次编译出的 `Image`、`build-info.txt` 等 | 是 | 是 | 这是推荐下载的刷机包。下载到的 artifact zip 本身就是可刷 AK3 包，不是空模板，也不是“等待再手动放内核”的准备目录。刷入时 AK3 会读取设备当前 boot 镜像，只替换其中的 kernel/Image，通常不改 ramdisk。 |
| `-Image` | 原始内核镜像文件 `Image` | 是 | 视工具而定 | 这是 `make` 后从 `common/out/arch/arm64/boot/Image` 导出的本次编译结果，不是手机原厂内核，也不是未修改源码。它已经包含所选的 SukiSU / SUSFS / Droidspaces / config 等改动。适合手动打包 boot.img、对比、或给支持直刷 Image 的工具使用。 |
| `-boot` | 由本次 `Image` 生成的 `boot.img` | 是 | 是，需 bootloader 已解锁且机型匹配 | 这是用本次编译出的 `Image` 重新打包出来的 boot 镜像，不是从手机提取的原厂 boot.img。Android 13+ GKI boot 通常不含 ramdisk，本项目按 header v4 生成，并用测试密钥补 AVB hash footer，使镜像格式完整。 |
| `-build-info` | `build-info.txt` | 否 | 否 | 构建信息记录文件，写明设备、源码 commit、SukiSU/SUSFS 版本、功能开关、构建器提交等。它也会复制进 `-AnyKernel3` 包内，方便刷机包离线追溯来源。 |
| `-final-config` | 最终 `.config` | 否 | 否 | 这是 `make gki_defconfig` 后真正参与编译的最终内核配置，用于核对某个 `CONFIG_*` 是否实际生效。即使启用了 `config_data` 伪装，这个 artifact 仍是构建期真实配置，不是伪装后的 `/proc/config.gz` 显示内容。 |
| `-patch-rejects` | 补丁冲突文件 `.rej` 及相关源码片段 | 否 | 否 | 只有补丁产生冲突时才上传，用于排查失败构建；成功构建通常没有这个 artifact。 |

简单选择：

- 日常刷机：下载 `-AnyKernel3`。
- 想确认这次到底开了哪些功能：下载 `-build-info`（AK3 包内也会带一份）。
- 想用 fastboot、手动刷 boot 分区、核对原始 `Image` 或最终 `.config`：先开启 `output_debug_artifacts`，再下载对应的 `-boot`、`-Image`、`-final-config`。

---

## 构建选项

Actions 的 `Run workflow` 参数按功能归类排列：先选基础目标，再选 SukiSU / SUSFS，随后是 Droidspaces、普通 config 增强、外部源码/补丁增强，最后才是输出与维护项。

### 1. 基础目标

| 选项 | 默认 | 说明 |
|---|---|---|
| `device` | `rmx5062` | 目标设备，读取 `devices/<设备>.env`。当前支持 realme Neo7 Turbo / RMX5062。 |

### 2. SukiSU / SUSFS / 隐藏

| 选项 | 默认 | 归类 | 说明 |
|---|---|---|---|
| `ksu_ref` | `builtin` | SukiSU | SukiSU-Ultra 分支/tag/commit。开 SUSFS 时必须用含 SUSFS 的 `builtin` 分支。 |
| `ksu_version_override` | 空 | SukiSU | 手工钉死 `KSU_VERSION`，用于匹配特定管理器 APK；留空则自动推导。 |
| `enable_kpm` | ✅ | SukiSU | 启用 KPM（Kernel Patch Module），这是 SukiSU-Ultra 自带的内核补丁模块框架；不额外拉仓库。 |
| `enable_susfs` | ✅ | SUSFS | 启用 SUSFS，用于挂载隐藏、路径隐藏、kstat/uname/cmdline 伪装等。 |
| `susfs_ref` | 空 | SUSFS | 钉死 `susfs4ksu` 到某个 commit；留空使用对应 GKI 分支最新提交。 |
| `enable_config_spoof` | ✅ | 隐藏 | 伪装 `/proc/config.gz` 里的显示内容，隐藏 `CONFIG_KSU` / `CONFIG_KSU_SUSFS` / `CONFIG_KPM` 等痕迹；不改变真实内核功能。 |
| `config_spoof_rules` | 空 | 隐藏 | 自定义伪装规则，如 `CONFIG_KSU=n CONFIG_KPM=n`；留空使用默认规则。 |

### 3. Droidspaces 容器支持

| 选项 | 默认 | 说明 |
|---|---|---|
| `enable_droidspaces` | ✅ | 启用 Droidspaces 所需的 namespace / IPC / devtmpfs 等内核能力，让 Linux 容器环境能正常运行。Droidspaces 本体是 userspace 程序，本项目不编译它，只提供内核支撑。 |
| `kabi_slots` | `auto` | Droidspaces 开启 `CONFIG_SYSVIPC` 会影响 `task_struct`，必须把字段放进 GKI 预留 kABI 槽位。`auto` 使用设备配置里的安全默认值；选错可能 bootloop。 |

### 4. 普通内核 config 增强

这些功能主要是写入 `config/*.config`，不拉取外部功能仓库，最后和整个内核一起编译。

| 选项 | 默认 | 说明 |
|---|---|---|
| `enable_network_ext` | ✅ | 启用 ipset / 高级 iptables / IPv6 NAT，给 Docker、UFW、fail2ban 等容器/防火墙场景提供内核支持。已按 `sm8650_kernel` 的 `better_net` 对齐。 |
| zram | 必选 | Android 常规内存压缩功能。本项目固定启用，且必须保持 `CONFIG_ZRAM=m` / `CONFIG_ZSMALLOC=m`，不提供关闭参数。 |
| `enable_bbr` | ❌ | 编入 BBR TCP 拥塞控制算法，但默认仍是 cubic；只是多一个可选算法。 |
| `bbr_as_default` | ❌ | 把 BBR 设置为全机 TCP 默认拥塞控制算法；必须同时开启 `enable_bbr`。会改变默认网络行为，建议稳定后再测试。 |

### 5. 外部源码 / 外部补丁增强

| 选项 | 默认 | 说明 |
|---|---|---|
| `enable_rekernel` | ❌ | 拉取 Re-Kernel 源码核对上游支持形态；RMX5062 默认不内建。上游 Android 5.10+ / GKI 推荐把 `LKM-Source` 编译成 `rekernel.ko` 使用，`Integrate/rekernel` 是给 <=5.4 或非 GKI/QGKI 内核的源码级集成路径。旧版强转 in-tree 已在实机验证会卡死/重启，因此不再默认启用。 |
| `enable_ntsync` | ❌ | 下载并应用 NTsync 补丁，给 Winlator / Wine / Proton 类场景提供同步原语。会把 `/dev/ntsync` 开放给所有 App，不跑 Winlator 不建议开启。 |
| `enable_bbg` | ❌ | 下载并运行 Baseband Guard 上游脚本，加入基带保护 LSM，防止误写非用户分区导致变砖。 |

### 6. 输出与维护

| 选项 | 默认 | 说明 |
|---|---|---|
| `kernel_suffix` | 空 | 自定义内核后缀；留空使用设备配置，尽量贴近原厂版本串。 |
| `output_boot_img` | ❌ | 是否在打包阶段生成 `boot.img`；只有同时开启 `output_debug_artifacts` 时才上传为 artifact。默认关闭，避免生成和上传非必要产物。 |
| `output_debug_artifacts` | ❌ | 额外上传 `-Image`、`-boot`、`-final-config`。默认关闭，所以成功构建默认只输出 AK3 和 build-info。 |
| `ccache_reset` | ❌ | 丢弃 ccache，强制冷编译。用于排除缓存造成的误判。 |

---

## 外部来源与各功能解决的问题

| 功能 | 是否拉取外部来源 | 来源 | 解决的问题 / 作用 |
|---|---|---|---|
| 设备内核源码 | 是 | `realme-kernel-opensource/realme_neo7_turbo-AndroidV-kernel-source` | RMX5062 的 6.1.115 Android GKI 内核源码，是所有功能集成的基础。 |
| 工具链 | 是 | `cctv18/oneplus_sm8650_toolchain` release；必要时还会取 AOSP `mkbootimg` / `kernel-build-tools` | 提供 clang、构建工具、boot.img 打包工具。 |
| SukiSU-Ultra | 是 | `https://github.com/SukiSU-Ultra/SukiSU-Ultra` 的官方 `kernel/setup.sh` | 提供 root 能力、Manager 通讯、KPM 框架以及 builtin 分支里的 SUSFS 侧支持。 |
| SukiSU built-in hook | 否 | 本仓库 `scripts/setup-ksu-builtin-hooks.sh` | 只开 SukiSU、不开 SUSFS 时补齐 built-in `[ksu_driver]` fd 通道，避免运行时退到 LKM 识别。 |
| SUSFS | 是 | 主源 `https://github.com/ShirkNeko/susfs4ksu.git`；回退源 `https://gitlab.com/simonpunk/susfs4ksu.git` | 提供挂载隐藏、路径隐藏、属性伪装、cmdline/bootconfig 伪装等 root 隐藏能力。 |
| Droidspaces 内核支撑 | 否 | 本仓库脚本与补丁；参考 Droidspaces-OSS 的内核需求 | 开启容器所需 namespace / IPC / devtmpfs，并用 kABI-safe 方式处理 `CONFIG_SYSVIPC`，解决容器能力缺失和 bootloop 风险。 |
| 网络功能扩展 | 否 | 本仓库 `config/network.config` | 启用 ipset / 高级 iptables / IPv6 NAT，解决 Docker、UFW、fail2ban 等网络规则能力不足。 |
| zram | 否 | 本仓库 `config/zram.config` | 保持原厂期望的模块化内存压缩，避免 zram 内建导致 oplus hybridswap 模块加载失败、App 无法启动。 |
| KPM | 否 | SukiSU-Ultra 源码内已有 Kconfig / 实现 | SukiSU 的内核补丁模块框架；启用主要是打开 `CONFIG_KPM` 和必要符号表配置。 |
| BBR | 否 | 内核已有 TCP 拥塞控制算法配置 | 改善特定高延迟/移动网络/代理场景下的 TCP 吞吐；默认不改变 cubic，除非开启 `bbr_as_default`。 |
| Re-Kernel | 是 | `https://github.com/Sakion-Team/Re-Kernel.git` | 目标是改善后台进程冻结/唤醒行为。上游 README 写明 Android 5.10+ / GKI 推荐使用 LKM/Magisk 模块，`Integrate/rekernel` 是 <=5.4 或非 GKI/QGKI 的源码级集成路径；RMX5062 旧版强转 in-tree 已实测卡死/重启，因此默认不内建。 |
| NTsync | 是 | `https://raw.githubusercontent.com/Goldzxcbug/Droidspaces_Kernel_patch/main/NTsync` | 给 Winlator / Wine / Proton 提供内核同步原语；不属于 Droidspaces 必需项。 |
| BBG | 是 | `https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh` | 加入基带保护，降低误刷/误写非用户分区造成变砖的风险。 |
| config_data 伪装 | 否 | 本仓库 `patches/optional/config_data_spoof.patch` | 只改 `/proc/config.gz` 对外显示，不改真实 `.config` 和内核功能，用于避免配置泄露改装痕迹。 |
| AnyKernel3 | 是 | `https://github.com/WildKernels/AnyKernel3.git` 的 `gki-2.0` 分支 | 生成可刷入的 AK3 包；下载到的 artifact zip 本身就是刷机包，不再 zip 套 zip。 |

---

## 刷入后的验证

刷完之后依次跑这几条，确认三个组件都真的生效：

```bash
# 1. SukiSU —— 打开管理器 App，应显示「已安装」且不报版本不匹配
#    若报版本不匹配，看构建日志里的 KSU_VERSION，用同期的管理器 APK

# 2. SUSFS
su -c 'ksud susfs version'    # 应返回 vX.Y.Z，不能是 unsupport
su -c 'ksud susfs status'     # 应返回 true
dmesg | grep -i susfs         # 应有 susfs_init 相关输出

# 3. Droidspaces
droidspaces --check           # 应显示 All required features found!
```

三条里任何一条不对，看 **[docs/troubleshooting.md](docs/troubleshooting.md)**。

---

## 已知问题

### SUSFS 版本可能高于管理器 assets

管理器 App 内置的 `ksu_susfs_<版本>` 二进制只有有限几个版本。若内核编译时
拿到的 SUSFS 版本超出这个范围，管理器 SUSFS 页面会报 `susfs_binary_not_found`。

**内核侧是好的** —— `ksud susfs version` 能正常返回版本号就说明内核没问题。

三个应对办法（按推荐度）：

1. 用与本次构建同期的 SukiSU 管理器 APK（其 assets 会同步更新）
2. 用 `susfs_ref` 输入项把 SUSFS 钉死到管理器支持的版本
3. 改用独立的 [susfs4ksu-module](https://github.com/sidex15/susfs4ksu-module)
   （运行时向内核问版本，不依赖管理器 assets）
   ⚠️ 它与 ksud 自带的 `susfs_manager` 功能重叠，不能同时启用

构建日志和 `build-info.txt` 里都会写明实际的 SUSFS 版本。

### 源码版本与固件版本可能错位

厂商开源仓库的更新往往滞后于 OTA。例如 realme Neo7 Turbo 的开源代码对应
固件 `15.0.1.542`，而设备上可能已经是 `15.0.1.971`。

两者内核主次版本相同时，GKI 的 KMI 保证二进制兼容，可以正常使用。

---

## 设计取舍

几个刻意的决定，以及背后的理由：

**用 SukiSU 的 `builtin` 分支而非 `main`。**
`main` 分支的内核侧对 SUSFS 是零支持 —— 没有 Kconfig 选项、没有
`susfs_init()` 调用、reboot 命令通道也只认自己的 magic 不认 SUSFS 的。
在 `main` 上手工搭适配层很容易漏掉调用点，症状是 `ksud susfs version`
永远返回 `unsupport`，管理器每次打开设置页都发一次注定超时的 root shell
请求，界面就卡死了。`builtin` 分支这些都是上游原生提供的。

**`CONFIG_ZRAM` / `CONFIG_ZSMALLOC` 必须保持 `=m`，绝不能改成内建。**
官方 `gki_defconfig` 原值就是 `CONFIG_ZRAM=m`，因为原厂 zram 由 oplus 的
vendor 模块接管（`oplus_bsp_hybridswap_zram` 等）。这套模块除了做混合交换，
还会在 memcg 里注册 15 个私有控制文件，其中 `memory.app_uid` 是
libprocessgroup **硬编码**要写的路径 —— Zygote fork 出每个 app 后调
`createProcessGroup()` 写它，写不进去就 JNI FatalError → abort。

编成内建（`=y`）会让这套模块加载失败，那 15 个文件全部消失。后果是
**能正常开机，但一个 app 都打不开**（init / system_server 不是从 Zygote
fork 的，不走这条路径，所以系统本身看着正常）。

本项目早期版本踩过这个坑。实测对比：`/dev/memcg/apps/uid_*/` 下
正常内核 46 个文件，改成 `=y` 后只剩 31 个。
`scripts/verify-config.sh` 现在会在编译前挡住 `=y`。

**关键步骤一律硬失败，不用 `|| true`。**
打补丁失败、配置项没生效这类问题，如果被吞掉，最终会以「刷机后某个功能
莫名不工作」的形式暴露出来，那时候排查成本高得多。宁可在构建期就红。

**不用 `patch -F 3` 放宽 fuzz。**
fuzz 能让上下文对不上的补丁「蒙混过关」，但打进去的位置未必对。
本项目对上下文差异敏感的改动（kABI 槽位注入）改用脚本直接注入，
不依赖行号和上下文，且每步都验证。

**ccache 用 `compilercheck=content` 而不是 `none`。**
`none` 命中率更高，但换工具链或补丁改了源码时有拿到陈旧目标文件的风险 ——
表现是「明明改了代码，产物却没变化」，很难往回追。牺牲一点首次命中率换正确性。

**config_data 伪装是可选项，默认开启。**
`CONFIG_IKCONFIG_PROC=y` 时内核会把编译用的 `.config` 原样嵌进镜像，
经 `/proc/config.gz` 暴露给任何进程 —— 不需要 root 就能读到 `CONFIG_KSU=y`。
SUSFS 在文件系统层做的隐藏，在这个口子上被整个绕过。

`enable_config_spoof` 开启后，会在 `config_data` 生成之后改写它的显示内容
（默认把 KSU / SUSFS / KPM 显示成未启用）。改的是产物副本而不是 `.config`
本身，所以**内核功能与不开时完全一致**，只有 `/proc/config.gz` 的显示变了。

要注意它的边界：这只堵 `/proc/config.gz` 一个口子，内核符号表等痕迹由
SUSFS 的 `HIDE_KSU_SUSFS_SYMBOLS` 负责。不开这个开关时，产物与不打补丁
逐字节相同。

---

## 仓库结构

```
.
├── .github/workflows/
│   ├── build.yml               核心构建引擎
│   └── cleanup.yml             定期清理旧产物与缓存
├── devices/
│   ├── _template.env           新增机型的模板（带完整注释）
│   └── rmx5062.env             realme Neo7 Turbo
├── scripts/
│   ├── lib/common.sh           日志、断言、幂等 config 操作
│   ├── prepare-toolchain.sh    下载 clang 与构建工具
│   ├── prepare-source.sh       获取内核源码（三种方式）
│   ├── prepare-vendor-stubs.sh 修复 zip 打包丢失的符号链接
│   ├── setup-ksu.sh            集成 SukiSU + 版本号校验
│   ├── setup-susfs.sh          SUSFS 补丁 + 上下文适配
│   ├── setup-droidspaces.sh    kABI 注入 + 容器配置
│   ├── setup-optional.sh       KPM / 网络扩展 / zram / Re-Kernel / BBR / NTsync / BBG / config_data 伪装
│   ├── apply-defconfig.sh      配置写入 + 版本串设置
│   ├── verify-config.sh        编译前自检（硬失败）
│   ├── build-kernel.sh         编译
│   └── package.sh              打包 AnyKernel3；按需导出 Image / boot.img
├── config/                     按功能拆分的 defconfig 片段
├── patches/                    补丁（每个都带中文说明其必要性）
└── docs/
    ├── add-device.md           如何添加新机型
    └── troubleshooting.md      排查手册
```

所有构建逻辑都在 `scripts/` 里，可以在本地单独运行调试：

```bash
export WORKSPACE=/tmp/kbuild REPO_ROOT=$(pwd)
. scripts/lib/common.sh && load_device rmx5062
bash scripts/prepare-source.sh
```

---

## 致谢

- [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra)
- [susfs4ksu](https://github.com/ShirkNeko/susfs4ksu) / [原版](https://gitlab.com/simonpunk/susfs4ksu)
- [Droidspaces-OSS](https://github.com/ravindu644/Droidspaces-OSS)
- [GKI_KernelSU_SUSFS](https://github.com/zzh20188/GKI_KernelSU_SUSFS) —— 本项目的 workflow 架构参考
- [AnyKernel3](https://github.com/WildKernels/AnyKernel3)
- [Re-Kernel](https://github.com/Sakion-Team/Re-Kernel)

## 许可

GPL-2.0，与 Linux 内核一致。
