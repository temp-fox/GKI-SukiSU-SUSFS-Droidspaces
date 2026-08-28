#!/usr/bin/env bash
# 公共函数库：日志、断言、defconfig 幂等操作、补丁应用。
#
# 所有构建脚本都 source 这个文件。设计原则：
#   1. 关键步骤硬失败，绝不 `|| true`
#   2. 所有写操作幂等，可重复执行
#   3. 每一步都有验证，失败时给出可操作的错误信息
#
# 依赖的环境变量（由 workflow 通过 GITHUB_ENV 传入，或本地 export）：
#   WORKSPACE   构建工作区，内含 common/ KernelSU/ vendor/
#   KERNEL_DIR  内核源码根，通常是 $WORKSPACE/common
#   DEFCONFIG   $KERNEL_DIR/arch/arm64/configs/gki_defconfig
#   REPO_ROOT   本仓库根目录（scripts/ config/ patches/ devices/ 所在）

set -euo pipefail

# ============================================================
# 日志
# ============================================================

log()  { printf '[*] %s\n' "$*"; }
ok()   { printf '[+] %s\n' "$*"; }
skip() { printf '[=] %s\n' "$*"; }

warn() {
    printf '[!] %s\n' "$*" >&2
    # GitHub Actions 注解，让警告在 Summary 里可见
    [ -n "${GITHUB_ACTIONS:-}" ] && printf '::warning::%s\n' "$*" || true
}

die() {
    printf '[x] %s\n' "$*" >&2
    [ -n "${GITHUB_ACTIONS:-}" ] && printf '::error::%s\n' "$*" || true
    exit 1
}

# 分节标题，让长日志可读
section() {
    printf '\n========== %s ==========\n' "$*"
}

# ============================================================
# 断言
# ============================================================

require_env() {
    local name
    for name in "$@"; do
        [ -n "${!name:-}" ] || die "环境变量 $name 未设置"
    done
}

require_file() {
    [ -f "$1" ] || die "文件不存在：$1${2:+（$2）}"
}

require_dir() {
    [ -d "$1" ] || die "目录不存在：$1${2:+（$2）}"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "命令不可用：$1${2:+（$2）}"
}

# 断言文件中包含某个固定字符串，用于验证改动确实生效
assert_contains() {
    local file="$1" pattern="$2" msg="${3:-}"
    grep -qF -- "$pattern" "$file" \
        || die "${msg:-验证失败}：$file 中未找到 [$pattern]"
}

assert_not_contains() {
    local file="$1" pattern="$2" msg="${3:-}"
    grep -qF -- "$pattern" "$file" \
        && die "${msg:-验证失败}：$file 中不应存在 [$pattern]" || true
}

# ============================================================
# defconfig 幂等操作
#
# 三分支模式（学 GKI_KernelSU_SUSFS）：
#   已是 =y            → 跳过
#   有 "# X is not set" → 就地替换
#   都没有             → 追加
# ============================================================

# enable_config CONFIG_FOO
enable_config() {
    local cfg="$1"
    require_env DEFCONFIG
    [ -f "$DEFCONFIG" ] || die "DEFCONFIG 不存在：$DEFCONFIG"

    if grep -q "^${cfg}=y\$" "$DEFCONFIG"; then
        skip "  已启用: $cfg"
        return 0
    fi

    if grep -q "^# ${cfg} is not set\$" "$DEFCONFIG"; then
        sed -i "s|^# ${cfg} is not set\$|${cfg}=y|" "$DEFCONFIG"
        ok "  已切换: $cfg （原为 is not set）"
    else
        # 可能存在 =m 或 =n，先清掉再追加，避免同一项出现两行
        sed -i "/^${cfg}=/d" "$DEFCONFIG"
        printf '%s=y\n' "$cfg" >> "$DEFCONFIG"
        ok "  已添加: $cfg"
    fi

    grep -q "^${cfg}=y\$" "$DEFCONFIG" || die "写入 $cfg=y 失败"
}

# disable_config CONFIG_FOO —— 写成 "# X is not set"
disable_config() {
    local cfg="$1"
    require_env DEFCONFIG

    if grep -q "^# ${cfg} is not set\$" "$DEFCONFIG"; then
        skip "  已禁用: $cfg"
        return 0
    fi

    sed -i "/^${cfg}=/d" "$DEFCONFIG"
    printf '# %s is not set\n' "$cfg" >> "$DEFCONFIG"
    ok "  已禁用: $cfg"
}

# set_config CONFIG_FOO value —— 用于非布尔项，如 CONFIG_IP_SET_MAX=65534
set_config() {
    local cfg="$1" val="$2"
    require_env DEFCONFIG

    if grep -q "^${cfg}=${val}\$" "$DEFCONFIG"; then
        skip "  已设置: $cfg=$val"
        return 0
    fi

    sed -i "/^${cfg}=/d;/^# ${cfg} is not set\$/d" "$DEFCONFIG"
    printf '%s=%s\n' "$cfg" "$val" >> "$DEFCONFIG"
    ok "  已设置: $cfg=$val"
}

# config_defined CONFIG_FOO —— 在 Kconfig 树里是否真有这个符号
#
# ⚠️ 这是防「静默丢弃」的关键。前身项目写过 CONFIG_KSU_SUSFS_SUS_OVERLAYFS
# 和 CONFIG_MQ_IOSCHED_SSG，两者的 Kconfig 符号都不存在，kconfig 会静默忽略，
# 构建照常通过但功能没有生效。
config_defined() {
    local name="${1#CONFIG_}"
    local search_dirs=()
    [ -d "${KERNEL_DIR:-}" ] && search_dirs+=("$KERNEL_DIR")
    [ -d "${WORKSPACE:-}/KernelSU" ] && search_dirs+=("$WORKSPACE/KernelSU")
    [ ${#search_dirs[@]} -eq 0 ] && return 1

    grep -RqsE --include='Kconfig*' \
        "^[[:space:]]*(menuconfig|config)[[:space:]]+${name}[[:space:]]*\$" \
        "${search_dirs[@]}"
}

# enable_config_if_defined CONFIG_FOO —— 符号存在才启用，否则告警
enable_config_if_defined() {
    local cfg="$1"
    if config_defined "$cfg"; then
        enable_config "$cfg"
    else
        warn "  Kconfig 中未定义 $cfg，跳过（写了也会被静默丢弃）"
    fi
}

# 从 config/*.config 片段批量导入。片段支持三种行：
#   CONFIG_FOO=y          → enable
#   CONFIG_FOO=<value>    → set
#   # CONFIG_FOO is not set → disable
#   # 其他注释 / 空行      → 忽略
apply_config_fragment() {
    local frag="$1"
    require_file "$frag" "config 片段"
    log "导入 config 片段: $(basename "$frag")"

    local line cfg val
    while IFS= read -r line || [ -n "$line" ]; do
        # 去掉行尾 CR（防止仓库被 Windows 检出时 CRLF 混入）
        line="${line%$'\r'}"
        case "$line" in
            ''|'#'*' is not set')
                if [[ "$line" =~ ^#[[:space:]]*(CONFIG_[A-Za-z0-9_]+)[[:space:]]+is[[:space:]]+not[[:space:]]+set$ ]]; then
                    disable_config "${BASH_REMATCH[1]}"
                fi
                ;;
            '#'*) : ;;
            CONFIG_*=*)
                cfg="${line%%=*}"
                val="${line#*=}"
                if [ "$val" = "y" ]; then
                    enable_config "$cfg"
                else
                    set_config "$cfg" "$val"
                fi
                ;;
        esac
    done < "$frag"
}

# ============================================================
# 补丁
# ============================================================

# apply_patch <补丁文件> [工作目录] [strip层级]
#
# 不加 fuzz、不吞异常。上下文对不上就应该失败并让人去看，
# 而不是 -F 3 蒙混过关（那正是前身项目的隐患来源）。
apply_patch() {
    local patch_file="$1"
    local workdir="${2:-.}"
    local strip="${3:-1}"

    require_file "$patch_file" "补丁"
    require_dir "$workdir"

    log "应用补丁: $(basename "$patch_file") （-p${strip} @ $workdir）"

    # 先 dry-run 判断是否已应用，实现幂等
    if patch -p"$strip" -d "$workdir" --dry-run --reverse --force \
            < "$patch_file" >/dev/null 2>&1; then
        skip "  补丁已应用过，跳过"
        return 0
    fi

    if ! patch -p"$strip" -d "$workdir" --forward --no-backup-if-mismatch \
            < "$patch_file"; then
        die "补丁应用失败: $patch_file
     上下文与当前源码不匹配。请检查 .rej 文件，或确认源码版本是否符合预期。
     不要用 -F 放宽 fuzz 绕过——那只会把问题推迟到刷机后。"
    fi

    ok "  补丁应用成功"
}

# 统计并列出 .rej 文件；有则失败
assert_no_rejects() {
    local dir="${1:-${KERNEL_DIR:-.}}"
    local label="${2:-补丁}"
    local count
    count=$(find "$dir" -name '*.rej' -type f 2>/dev/null | wc -l)
    if [ "$count" -gt 0 ]; then
        printf '\n以下补丁产生了冲突：\n' >&2
        find "$dir" -name '*.rej' -type f -print >&2
        die "${label}产生了 ${count} 个 .rej 冲突文件"
    fi
    ok "  无 .rej 冲突"
}

# ============================================================
# GitHub Actions 输出
# ============================================================

# 写入 $GITHUB_ENV（本地运行时降级为 export 提示）
put_env() {
    local key="$1" val="$2"
    export "${key}=${val}"
    if [ -n "${GITHUB_ENV:-}" ]; then
        printf '%s=%s\n' "$key" "$val" >> "$GITHUB_ENV"
    fi
    log "  $key=$val"
}

put_output() {
    local key="$1" val="$2"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf '%s=%s\n' "$key" "$val" >> "$GITHUB_OUTPUT"
    fi
}

# ============================================================
# 设备配置加载
# ============================================================

load_device() {
    local code="$1"
    require_env REPO_ROOT
    local env_file="$REPO_ROOT/devices/${code}.env"

    # _template 是给人复制的骨架，里面是占位值。直接拿它构建会在很深的
    # 地方失败（下载不存在的仓库），错误信息还指不到根因，所以在这里拦掉。
    case "$code" in
        _*) die "devices/${code}.env 是模板，不能直接用于构建。
     请复制一份改名为你的机型代号，详见 docs/add-device.md" ;;
    esac

    [ -f "$env_file" ] || {
        printf '可用的设备配置：\n' >&2
        # 过滤掉 _template —— 它是给人复制的模板，不是可构建的机型
        ls -1 "$REPO_ROOT/devices/"*.env 2>/dev/null \
            | xargs -rn1 basename | sed 's/\.env$//' \
            | grep -v '^_' | sed 's/^/  - /' >&2
        die "设备配置不存在：$env_file
     新增机型请复制 devices/_template.env，详见 docs/add-device.md"
    }

    log "加载设备配置: $env_file"
    # shellcheck disable=SC1090
    set -a; . "$env_file"; set +a

    # 必填项校验 —— 缺一个就说清楚缺哪个，别让人到编译期才发现
    local required=(DEVICE_CODE DEVICE_NAME SOURCE_TYPE SOURCE_REPO SOURCE_REF
                    ANDROID_VERSION KERNEL_VERSION KERNEL_SUBLEVEL)
    local miss=()
    local k
    for k in "${required[@]}"; do
        [ -n "${!k:-}" ] || miss+=("$k")
    done
    [ ${#miss[@]} -eq 0 ] || die "设备配置 $env_file 缺少必填项：${miss[*]}"

    [ "$DEVICE_CODE" = "$code" ] \
        || die "设备配置内的 DEVICE_CODE=$DEVICE_CODE 与文件名 ${code}.env 不一致"

    ok "设备: $DEVICE_NAME (${DEVICE_CODE}) / 内核 ${KERNEL_VERSION}.${KERNEL_SUBLEVEL}-${ANDROID_VERSION}"
}

# ============================================================
# 布尔值归一化
#
# workflow_dispatch 的 boolean 输入在传给脚本时是字符串，
# 而 workflow_call 又可能传真 boolean。统一成 true/false。
# ============================================================

is_true() {
    case "${1:-}" in
        true|True|TRUE|1|yes|y|on) return 0 ;;
        *) return 1 ;;
    esac
}
