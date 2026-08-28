# GKI-SukiSU-SUSFS-Droidspaces

用 GitHub Actions 编译 Android GKI 内核，集成三样东西：

| 组件 | 作用 |
|---|---|
| **[SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra)** | root 方案 |
| **[SUSFS](https://github.com/ShirkNeko/susfs4ksu)** | 挂载与文件隐藏 |
| **[Droidspaces](https://github.com/ravindu644/Droidspaces-OSS)** | Linux 容器运行时的内核支撑 |

**设备可插拔** —— 添加新机型 = 新增一个 `devices/<机型>.env` 文件，不改 workflow。

---

## 快速开始

1. Fork 本仓库
2. 打开 Actions 页面 → 左侧选「构建内核」→ 右上角 `Run workflow`
3. 选择设备，其余保持默认即可
4. 构建约 40–70 分钟（首次冷编译更久，之后有 ccache 会快很多）
5. 从 Artifacts 下载 `AnyKernel3_*.zip`，用 TWRP / KernelFlasher 刷入

> 刷之前先备份 boot 分区。

---

## 支持的设备

| 机型 | 代号 | 内核 | 状态 |
|---|---|---|---|
| realme Neo7 Turbo | `rmx5062` | 6.1.115-android14-11 | 首发支持 |

添加你的机型见 **[docs/add-device.md](docs/add-device.md)**。

---

## 构建选项

| 选项 | 默认 | 说明 |
|---|---|---|
| `device` | `rmx5062` | 目标设备 |
| `ksu_ref` | `builtin` | SukiSU 分支。⚠️ 开 SUSFS 时必须用含 SUSFS 的分支 |
| `ksu_version_override` | 空 | 手工钉死 KSU_VERSION，用于匹配特定管理器 APK |
| `enable_susfs` | ✅ | SUSFS 隐藏功能 |
| `susfs_ref` | 空 | 钉死 susfs4ksu 到某个 commit |
| `enable_droidspaces` | ✅ | 容器支持 |
| `kabi_slots` | `auto` | kABI 槽位，`auto` = 用设备配置的默认值 |
| `enable_kpm` | ✅ | SukiSU 的内核补丁模块框架 |
| `enable_network_ext` | ✅ | ipset / 高级 iptables（容器跑 Docker、UFW 需要） |
| `enable_zram` | ✅ | 内存压缩，对跑容器的机器有利 |
| `enable_rekernel` | ✅ | 改善后台进程冻结行为 |
| `enable_bbr` | ❌ | BBR 拥塞控制算法 |
| `enable_ntsync` | ❌ | Winlator 需要。⚠️ 会把 `/dev/ntsync` 开放给所有 App |
| `enable_bbg` | ❌ | 基带保护，防误刷变砖 |
| `kernel_suffix` | 空 | 自定义内核后缀，留空则伪装成原厂版本串 |
| `output_boot_img` | ✅ | 同时产出 boot.img |
| `ccache_reset` | ❌ | 丢弃缓存，强制冷编译 |

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
│   ├── setup-optional.sh       KPM / zram / Re-Kernel / BBR / NTsync / BBG
│   ├── apply-defconfig.sh      配置写入 + 版本串设置
│   ├── verify-config.sh        编译前自检（硬失败）
│   ├── build-kernel.sh         编译
│   └── package.sh              打包 AnyKernel3 + boot.img
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
