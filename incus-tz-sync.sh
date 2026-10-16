#!/usr/bin/env bash
#===============================================================================
# incus-tz-sync.sh — 让 Incus 实例(容器/虚拟机)的时区始终与宿主机保持一致
#
# 为什么需要它:
#   LXC 容器与宿主机共用同一个内核时钟, 绝对时间(epoch)本来就是一致的,
#   “时间对不上” 几乎都是因为容器里的时区配置(/etc/localtime、/etc/timezone、
#   /etc/TZ)与宿主机不同。本脚本把容器时区强制对齐到宿主机。
#
# 能力:
#   1) 事件守护: 监听 incus 生命周期事件, 实例 “创建/启动” 的瞬间就写正确时区
#      (创建时先写 incus 配置 environment.TZ, 启动后立即改容器内时区文件)
#   2) 一键检测: 列出所有实例的时区、偏移、容器内时间、与宿主机的时间差、结论
#   3) 一键校准: 全部实例 / 单个实例
#   4) 兼容任意发行版容器: Alpine(busybox/musl)、Debian、Ubuntu、RHEL 系…
#      容器内没有 tzdata 时直接从宿主机把 zoneinfo 文件推进去, 不依赖容器联网
#
# 目标环境: Debian/Ubuntu 宿主机 + incus CLI (bash 4.4+, 可选 systemd 用于自启)
#
# 用法: ./incus-tz-sync.sh help
#===============================================================================

set -uo pipefail
umask 022

readonly SCRIPT_VERSION="1.0.0"
readonly UNIT_SERVICE="incus-tz-sync.service"
readonly UNIT_RECONCILE="incus-tz-sync-reconcile.service"
readonly UNIT_TIMER="incus-tz-sync.timer"
readonly BIN_PATH="/usr/local/bin/incus-tz-sync"
readonly SELF_PATH="${BASH_SOURCE[0]}"

#-------------------------------------------------------------------------------
# 可配置项 (可被 /etc/incus-tz-sync.conf 或环境变量覆盖)
#-------------------------------------------------------------------------------
CONF_FILE="${INCUS_TZ_SYNC_CONF:-/etc/incus-tz-sync.conf}"
INCUS_BIN="${INCUS_BIN:-}"                 # 留空自动探测 incus / lxc
HOST_TZ_OVERRIDE="${HOST_TZ_OVERRIDE:-}"   # 强制指定宿主机时区, 如 Asia/Shanghai
DEFAULT_PROJECT="${DEFAULT_PROJECT:-}"     # 只处理某个 incus 项目(留空=所有项目)
IGNORE_CONTAINERS="${IGNORE_CONTAINERS:-}" # 逗号分隔, 支持通配, 如 "router-*,test"
SET_ENV_TZ="${SET_ENV_TZ:-1}"              # 是否同时写 incus 配置 environment.TZ
ENFORCE_NAME="${ENFORCE_NAME:-1}"          # 偏移相同但时区名不同也改成一致
TZ_DATA_INSTALL="${TZ_DATA_INSTALL:-0}"    # 容器缺 tzdata 时是否允许在容器内装包
READY_TIMEOUT="${READY_TIMEOUT:-120}"      # 等待实例可 exec 的最长秒数
READY_INTERVAL="${READY_INTERVAL:-2}"      # 等待轮询间隔
EXEC_TIMEOUT="${EXEC_TIMEOUT:-20}"         # 单次 incus exec 超时
LOG_FILE="${LOG_FILE:-/var/log/incus-tz-sync.log}"
STATE_DIR="${STATE_DIR:-/run/incus-tz-sync}"
TIMER_INTERVAL="${TIMER_INTERVAL:-15min}"  # 兜底定时校准周期
MENU_COMMAND="${MENU_COMMAND:-admindate}"  # install 时创建的快捷命令(留空=不创建)

# 运行时状态
OPT_QUIET=0
OPT_DRY_RUN=0
OPT_FORCE=0
OPT_VERBOSE=0
OPT_ALL_PROJECTS=1
OPT_PROJECT=""
OPT_NO_TIMER=0
HOST_TZ=""
HOST_OFFSET=""
HOST_ZONE=""
HOST_EPOCH=""

declare -A PV=()   # 最近一次容器内探测结果

#-------------------------------------------------------------------------------
# 输出辅助
#-------------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_CYN=$'\033[36m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_BLD=""; C_RST=""
fi

_msg()  { [ "$OPT_QUIET" = 1 ] || printf '%s\n' "$*"; }
info()  { _msg "${C_CYN}[信息]${C_RST} $*"; }
okmsg() { _msg "${C_GRN}[成功]${C_RST} $*"; }
warn()  { printf '%s\n' "${C_YEL}[警告]${C_RST} $*" >&2; }
err()   { printf '%s\n' "${C_RED}[错误]${C_RST} $*" >&2; }
debug() { [ "$OPT_VERBOSE" = 1 ] && printf '%s\n' "${C_CYN}[调试]${C_RST} $*" >&2; return 0; }
die()   { err "$*"; exit 1; }

elog() {  # 守护进程日志
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

usage() {
  cat <<EOF
${C_BLD}incus-tz-sync v${SCRIPT_VERSION}${C_RST} — 让 Incus 实例时区始终与宿主机一致

用法: ${0##*/} [全局选项] <命令> [参数]

命令:
  menu                    交互式菜单(不带参数直接运行就是它)
  check                   一键检测: 所有实例的时区/偏移/时间差与结论
  sync-all                一键校准: 把所有运行中的实例对齐到宿主机时区
  sync <实例名>           校准单个实例
  watch                   前台运行事件守护(实时看日志), Ctrl-C 退出
  daemon                  watch 的静默版, 供 systemd 使用
  install                 安装到 $BIN_PATH, 启用 systemd 服务+定时器,
                          并创建快捷命令 $MENU_COMMAND (敲它直接进菜单)
  uninstall               卸载 systemd 服务与定时器、快捷命令(保留配置和日志)
  status                  查看宿主机时区、实例数量、守护状态
  log                     查看守护日志最后 40 行
  help                    显示本帮助

全局选项:
  -q, --quiet             安静模式(只输出结果)
  -n, --dry-run           演练: 只说明会做什么, 不真正修改
  -f, --force             即使已一致也重写一遍
      --project <名称>    只操作指定 incus 项目(默认处理所有项目)
      --no-timer          install 时不安装兜底定时器
  -v, --verbose           输出调试信息
  -V, --version           显示版本

示例:
  sudo ./incus-tz-sync.sh                 # 交互菜单
  sudo ./incus-tz-sync.sh check           # 看哪些容器时区不一致
  sudo ./incus-tz-sync.sh sync-all        # 一键全部校准
  sudo ./incus-tz-sync.sh sync web        # 只校准 web
  sudo ./incus-tz-sync.sh install         # 装好后敲 admindate 即可进菜单
  sudo admindate                          # install 之后: 直接打开菜单
  sudo ./incus-tz-sync.sh install         # 开启“新建容器立即同步”

配置文件: $CONF_FILE
EOF
}

#-------------------------------------------------------------------------------
# 基础工具
#-------------------------------------------------------------------------------
need_cmd() { command -v "$1" >/dev/null 2>&1; }

find_incus() {
  local c
  if [ -n "$INCUS_BIN" ]; then
    if [ -x "$INCUS_BIN" ]; then return 0; fi
    if command -v "$INCUS_BIN" >/dev/null 2>&1; then INCUS_BIN="$(command -v "$INCUS_BIN")"; return 0; fi
  fi
  for c in incus lxc; do
    if command -v "$c" >/dev/null 2>&1; then INCUS_BIN="$(command -v "$c")"; return 0; fi
  done
  return 1
}

require_access() {  # 只要能用 incus 就行(root 或 incus-admin 组)
  [ "$(id -u)" = "0" ] && return 0
  # 用最保守的 list 形式探测, 老版本 incus 也支持
  if "$INCUS_BIN" list -c n -f csv >/dev/null 2>&1; then
    return 0
  fi
  err "当前用户没有访问 incus 的权限。请用 root 运行, 例如: sudo ${0##*/} $*"
  exit 1
}

require_root() {
  [ "$(id -u)" = "0" ] && return 0
  err "该操作需要 root 权限, 例如: sudo ${0##*/} $*"
  exit 1
}

tmo() {  # 带超时执行, 防止 frozen 实例把脚本挂死
  local t="$1"; shift
  if need_cmd timeout; then timeout --signal=TERM "$t" "$@"; else "$@"; fi
}

incus_i() {  # incus_i <项目|空> <incus 参数...>
  local p="$1"; shift
  if [ -n "$p" ]; then "$INCUS_BIN" --project "$p" "$@"; else "$INCUS_BIN" "$@"; fi
}

iexec_sh() {  # iexec_sh <项目> <实例> <shell脚本内容>
  local p="$1" n="$2" s="$3"
  if [ -n "$p" ]; then
    tmo "$EXEC_TIMEOUT" "$INCUS_BIN" --project "$p" exec "$n" -- /bin/sh -c "$s" </dev/null
  else
    tmo "$EXEC_TIMEOUT" "$INCUS_BIN" exec "$n" -- /bin/sh -c "$s" </dev/null
  fi
}

mkdir_p() { [ -d "$1" ] || mkdir -p "$1" 2>/dev/null || true; }

valid_command_name() {  # 快捷命令名只允许常规字符, 避免拼出危险的路径
  case "${1:-}" in
    ""|*[!A-Za-z0-9._-]*|.|..) return 1 ;;
    *) return 0 ;;
  esac
}

is_ignored() {
  local n="$1" pat oldifs
  [ -n "$IGNORE_CONTAINERS" ] || return 1
  oldifs="$IFS"; IFS=','
  for pat in $IGNORE_CONTAINERS; do
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2254
    case "$n" in $pat) IFS="$oldifs"; return 0 ;; esac
  done
  IFS="$oldifs"
  return 1
}

lock_tag() { printf '%s' "${1:-default}_${2}" | tr -c 'A-Za-z0-9_.-' '_'; }

#-------------------------------------------------------------------------------
# 宿主机时区
#-------------------------------------------------------------------------------
detect_host_tz() {
  local tz="" lt=""
  if [ -n "$HOST_TZ_OVERRIDE" ]; then
    tz="$HOST_TZ_OVERRIDE"
  elif need_cmd timedatectl; then
    tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  fi
  if [ -z "$tz" ] && [ -r /etc/timezone ]; then
    tz="$(head -n1 /etc/timezone 2>/dev/null || true)"
  fi
  if [ -z "$tz" ]; then
    lt="$(readlink -f /etc/localtime 2>/dev/null || true)"
    case "$lt" in */zoneinfo/*) tz="${lt#*/zoneinfo/}" ;; esac
  fi
  tz="${tz%%[[:space:]]*}"
  case "$tz" in
    ""|*[!A-Za-z0-9_+/-]*) return 1 ;;
  esac
  case "$tz" in ..*|*/../*|*/..|*/) return 1 ;; esac
  [ -f "/usr/share/zoneinfo/$tz" ] || return 1
  printf '%s' "$tz"
}

load_host_env() {
  HOST_TZ="$(detect_host_tz)" || die "无法识别宿主机时区。可在 $CONF_FILE 里设置 HOST_TZ_OVERRIDE=\"Asia/Shanghai\" 指定。"
  [ -f "/usr/share/zoneinfo/$HOST_TZ" ] || die "宿主机缺少 /usr/share/zoneinfo/$HOST_TZ, 请先安装 tzdata。"
  HOST_OFFSET="$(date '+%z')"
  HOST_ZONE="$(date '+%Z')"
  HOST_EPOCH="$(date '+%s')"
}

#-------------------------------------------------------------------------------
# 实例清单: 输出 名称<TAB>项目<TAB>environment.TZ
#-------------------------------------------------------------------------------
_LIST_OUT=""
_LIST_COLS=""
_LIST_HEADER=0

_cols_count() {  # "-c" 后面那个规格字符串实际会输出几列
  local spec="$1" part cnt=0
  local IFS=','
  for part in $spec; do
    case "$part" in
      *:*|*.*) cnt=$((cnt + 1)) ;;            # 自定义列 config:key / key
      *)       cnt=$((cnt + ${#part})) ;;      # 简写字符, 一个字符一列
    esac
  done
  printf '%s' "$cnt"
}

try_list_once() {  # $@ = 'list' 之后的全部参数
  local out
  if out="$("$INCUS_BIN" list "$@" 2>/dev/null)"; then
    _LIST_OUT="$out"
    return 0
  fi
  return 1
}

_render_list() {
  local ncols="$(_cols_count "$_LIST_COLS")"
  local line first=1 n p e
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "$_LIST_HEADER" = 1 ] && [ "$first" = 1 ]; then
      first=0
      case "${line%%,*}" in NAME|Name) continue ;; esac
    fi
    first=0
    n=""; p=""; e=""
    if [ "$ncols" -ge 3 ]; then
      IFS=, read -r n p e <<<"$line"
    elif [ "$ncols" = 2 ]; then
      case "$_LIST_COLS" in
        ne) IFS=, read -r n p <<<"$line" ;;
        *)  IFS=, read -r n e <<<"$line" ;;
      esac
    else
      IFS=, read -r n <<<"$line"
    fi
    [ -n "$n" ] || continue
    printf '%s\t%s\t%s\n' "$n" "$p" "$e"
  done <<<"$_LIST_OUT"
}

list_instances() {
  local -a variants=() pre=()
  if [ -n "$OPT_PROJECT" ]; then
    variants=("")
    pre=(--project "$OPT_PROJECT")
  else
    variants=(--all-projects "")
  fi
  local v cols fmt
  for v in "${variants[@]}"; do
    local -a va=()
    [ -n "$v" ] && va=("$v")
    for cols in "ne,config:environment.TZ" "ne" "n,config:environment.TZ" "n"; do
      for fmt in "csv,noheader" "csv"; do
        if try_list_once "${va[@]}" "${pre[@]}" -c "$cols" -f "$fmt"; then
          _LIST_COLS="$cols"
          _LIST_HEADER=0
          [ "$fmt" = "csv" ] && _LIST_HEADER=1
          _render_list
          return 0
        fi
      done
    done
  done
  return 1
}

instance_info() {  # 回显 "状态|类型"; 例如 RUNNING|container
  local p="$1" n="$2" out st ty
  if [ -n "$p" ]; then
    out="$("$INCUS_BIN" --project "$p" info "$n" 2>/dev/null)" || return 1
  else
    out="$("$INCUS_BIN" info "$n" 2>/dev/null)" || return 1
  fi
  st="$(printf '%s\n' "$out" | sed -n 's/^[Ss]tatus:[[:space:]]*//p' | head -n1 | tr -d '\r')"
  ty="$(printf '%s\n' "$out" | sed -n 's/^[Tt]ype:[[:space:]]*//p' | head -n1 | tr -d '\r')"
  [ -n "$st" ] || st="UNKNOWN"
  [ -n "$ty" ] || ty="container"
  printf '%s|%s' "$(printf '%s' "$st" | tr '[:lower:]' '[:upper:]')" "$ty"
}

is_running() {  # is_running <项目> <实例>
  local inf
  inf="$(instance_info "$1" "$2")" || return 1
  [ "${inf%%|*}" = "RUNNING" ]
}

#-------------------------------------------------------------------------------
# 容器内探测
#-------------------------------------------------------------------------------
PROBE_TEMPLATE='
echo "P_TZFILE=$(head -n1 /etc/TZ 2>/dev/null)"
echo "P_TZDEB=$(head -n1 /etc/timezone 2>/dev/null)"
if [ -L /etc/localtime ]; then
  echo "P_LT=symlink"
  echo "P_LTRAW=$(readlink /etc/localtime 2>/dev/null)"
  echo "P_LTFULL=$(readlink -f /etc/localtime 2>/dev/null)"
elif [ -e /etc/localtime ]; then
  echo "P_LT=file"
  echo "P_LTRAW="
  echo "P_LTFULL="
else
  echo "P_LT=missing"
  echo "P_LTRAW="
  echo "P_LTFULL="
fi
if [ -d /usr/share/zoneinfo ]; then echo "P_ZONEINFO=1"; else echo "P_ZONEINFO=0"; fi
if [ -f /usr/share/zoneinfo/__HOST_TZ__ ]; then echo "P_ZONEFILE=1"; else echo "P_ZONEFILE=0"; fi
echo "P_DATE=$(date "+%Y-%m-%d %H:%M:%S" 2>/dev/null)"
echo "P_ZONE=$(date "+%Z" 2>/dev/null)"
echo "P_OFFSET=$(date "+%z" 2>/dev/null)"
echo "P_EPOCH=$(date "+%s" 2>/dev/null)"
echo "P_DONE=1"
'

pv() { printf '%s' "${PV[$1]:-}"; }

_tz_name_ok() {
  local c="$1"
  [ -n "$c" ] || return 1
  case "$c" in /*|*..*) return 1 ;; esac
  [ -f "/usr/share/zoneinfo/$c" ]
}

_tz_from_path() {
  local raw="$1"
  raw="${raw#/usr/share/zoneinfo/}"
  raw="${raw#../usr/share/zoneinfo/}"
  raw="${raw#./}"
  if _tz_name_ok "$raw"; then printf '%s' "$raw"; return 0; fi
  return 1
}

run_probe() {  # run_probe <项目> <实例> ; 结果写入 PV
  local p="$1" n="$2" script out line k v
  PV=()
  script="$(printf '%s' "$PROBE_TEMPLATE" | sed "s|__HOST_TZ__|$HOST_TZ|g")"
  out="$(iexec_sh "$p" "$n" "$script" 2>/dev/null)" || return 1
  case "$out" in *P_DONE=1*) ;; *) return 1 ;; esac
  while IFS= read -r line; do
    case "$line" in
      P_*=*) k="${line%%=*}"; v="${line#*=}"; PV["$k"]="$v" ;;
    esac
  done <<<"$out"
  return 0
}

EV_STATE=""; EV_TZ=""; EV_OFFSET=""; EV_DATE=""; EV_DELTA=""; EV_NOTE=""

evaluate_instance() {  # 0=探测成功(结果见 EV_*), 1=无法探测
  local p="$1" n="$2"
  EV_STATE=""; EV_TZ=""; EV_OFFSET=""; EV_DATE=""; EV_DELTA=""; EV_NOTE=""
  if ! run_probe "$p" "$n"; then
    EV_STATE="UNREACHABLE"
    EV_NOTE="无法在实例内执行命令(未启动/卡死/无 /bin/sh)"
    return 1
  fi
  EV_OFFSET="$(pv P_OFFSET)"; EV_DATE="$(pv P_DATE)"
  local cepoch; cepoch="$(pv P_EPOCH)"
  if [ -n "$cepoch" ] && [ -n "$HOST_EPOCH" ]; then
    case "$cepoch" in ''|*[!0-9]*) : ;; *) EV_DELTA="$((cepoch - HOST_EPOCH))" ;; esac
  fi

  local cand="" raw
  for raw in "$(pv P_TZFILE)" "$(pv P_LTFULL)" "$(pv P_LTRAW)" "$(pv P_TZDEB)"; do
    [ -n "$raw" ] || continue
    if cand="$(_tz_from_path "$raw")"; then break; fi
    cand=""
  done
  EV_TZ="$cand"

  if [ "$(pv P_LT)" != "symlink" ] && [ "$(pv P_LT)" != "file" ]; then
    EV_STATE="MISMATCH"; EV_NOTE="/etc/localtime 不存在"
    return 0
  fi

  if [ "$cand" = "$HOST_TZ" ]; then
    if [ "$(pv P_ZONEFILE)" != "1" ]; then
      EV_STATE="NO_TZDATA"; EV_NOTE="缺少 /usr/share/zoneinfo/$HOST_TZ"
    elif [ "$EV_OFFSET" = "$HOST_OFFSET" ]; then
      EV_STATE="OK"; EV_NOTE="一致"
    else
      EV_STATE="MISMATCH"; EV_NOTE="时区名相同但偏移不同(容器 tzdata 可能过旧)"
    fi
  elif [ -z "$cand" ]; then
    if [ "$EV_OFFSET" = "$HOST_OFFSET" ]; then
      EV_STATE="UNKNOWN"; EV_NOTE="/etc/localtime 无法识别出时区名(偏移一致)"
    else
      EV_STATE="MISMATCH"; EV_NOTE="无法识别时区名且偏移不同"
    fi
  else
    if [ "$EV_OFFSET" = "$HOST_OFFSET" ]; then
      EV_STATE="NAME_ONLY"; EV_NOTE="偏移相同但时区名不同"
    else
      EV_STATE="MISMATCH"; EV_NOTE="时区不同"
    fi
  fi
  return 0
}

state_label() {
  case "$1" in
    OK)          printf '%s' "一致" ;;
    NAME_ONLY)   printf '%s' "名称不同(偏移一致)" ;;
    NO_TZDATA)   printf '%s' "容器缺 tzdata" ;;
    UNKNOWN)     printf '%s' "时区名无法识别" ;;
    MISMATCH)    printf '%s' "时区不一致" ;;
    UNREACHABLE) printf '%s' "无法进入实例" ;;
    *)           printf '%s' "$1" ;;
  esac
}

state_color() {
  case "$1" in
    OK) printf '%s' "$C_GRN" ;;
    MISMATCH|UNREACHABLE) printf '%s' "$C_RED" ;;
    *) printf '%s' "$C_YEL" ;;
  esac
}

#-------------------------------------------------------------------------------
# 写入时区
#-------------------------------------------------------------------------------
push_zoneinfo() {  # 返回 0 表示容器内已具备该 zone 文件
  local p="$1" n="$2" src="/usr/share/zoneinfo/$HOST_TZ" dst="/usr/share/zoneinfo/$HOST_TZ"
  local dstdir="/usr/share/zoneinfo"
  case "$HOST_TZ" in */*) dstdir="/usr/share/zoneinfo/${HOST_TZ%/*}" ;; esac

  if [ "$TZ_DATA_INSTALL" = 1 ]; then
    info "尝试在 $n 内安装 tzdata…"
    iexec_sh "$p" "$n" 'if command -v apk >/dev/null 2>&1; then apk add --no-cache tzdata >/dev/null 2>&1; elif command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get install -y tzdata >/dev/null 2>&1; fi; true' >/dev/null 2>&1 || true
    if run_probe "$p" "$n" && [ "$(pv P_ZONEFILE)" = "1" ]; then return 0; fi
  fi

  debug "从宿主机推送 zoneinfo: $src -> $n:$dst"
  if [ "$OPT_DRY_RUN" = 1 ]; then return 0; fi
  if incus_i "$p" file push --create-dirs "$src" "$n$dst" >/dev/null 2>&1; then return 0; fi
  iexec_sh "$p" "$n" "mkdir -p '$dstdir'" >/dev/null 2>&1 || true
  if incus_i "$p" file push "$src" "$n$dst" >/dev/null 2>&1; then return 0; fi
  return 1
}

apply_tz() {  # apply_tz <项目> <实例> [--wait-ready]
  local p="$1" n="$2" mode="${3:-}"
  local tag="$n"; [ -n "$p" ] && tag="$p/$n"

  if [ "$OPT_DRY_RUN" = 1 ]; then
    info "[演练] 将把 $tag 的时区写为 $HOST_TZ"
    return 0
  fi

  if [ "$mode" = "--wait-ready" ]; then
    wait_ready "$p" "$n" || { err "$tag 在 ${READY_TIMEOUT}s 内仍无法执行命令, 跳过"; return 1; }
  fi
  [ "$(pv P_DONE)" = "1" ] || { run_probe "$p" "$n" || true; }

  # 1) 容器内要有 zoneinfo 文件
  if [ "$(pv P_ZONEFILE)" != "1" ]; then
    info "$tag 容器内缺少 /usr/share/zoneinfo/$HOST_TZ, 正在补齐…"
    if ! push_zoneinfo "$p" "$n"; then
      err "$tag 无法准备时区数据(容器文件系统只读或磁盘已满?)"
      return 1
    fi
  fi

  # 2) 写时区文件: Debian/Ubuntu 用 /etc/localtime + /etc/timezone, Alpine/busybox 用 /etc/localtime + /etc/TZ
  local rc=0
  if ! iexec_sh "$p" "$n" "
rc=0
rm -f /etc/localtime 2>/dev/null || rc=1
ln -s /usr/share/zoneinfo/$HOST_TZ /etc/localtime 2>/dev/null || rc=1
printf '%s\n' '$HOST_TZ' > /etc/timezone 2>/dev/null || rc=1
printf '%s\n' '$HOST_TZ' > /etc/TZ 2>/dev/null || rc=1
exit \$rc
" >/dev/null 2>&1; then
    rc=1
  fi
  if [ "$rc" != "0" ]; then
    err "$tag 写入时区文件失败(容器内 /etc 可能只读)"
    return 1
  fi

  # 3) 同步 incus 配置 environment.TZ, 让容器内的进程一开始就带正确时区
  if [ "$SET_ENV_TZ" = 1 ]; then
    local cur
    cur="$(incus_i "$p" config get "$n" environment.TZ 2>/dev/null || true)"
    cur="${cur%%$'\n'*}"
    if [ "$cur" != "$HOST_TZ" ]; then
      incus_i "$p" config set "$n" environment.TZ "$HOST_TZ" >/dev/null 2>&1 \
        || warn "$tag 写入 incus 配置 environment.TZ 失败"
    fi
  fi

  # 4) 复核
  if evaluate_instance "$p" "$n"; then
    [ "$EV_STATE" = "OK" ] && return 0
    err "$tag 写入后复核仍未通过: $(state_label "$EV_STATE") ($EV_NOTE)"
    return 1
  fi
  err "$tag 写入后无法复核"
  return 1
}

set_env_tz_only() {  # 容器还没启动时只能先写 incus 配置
  local p="$1" n="$2"
  [ "$SET_ENV_TZ" = 1 ] || return 0
  if [ "$OPT_DRY_RUN" = 1 ]; then info "[演练] 将为 $n 预设 environment.TZ=$HOST_TZ"; return 0; fi
  incus_i "$p" config set "$n" environment.TZ "$HOST_TZ" >/dev/null 2>&1
}

wait_ready() {  # 等实例可执行命令
  local p="$1" n="$2" waited=0 inf
  while [ "$waited" -lt "$READY_TIMEOUT" ]; do
    if iexec_sh "$p" "$n" 'exit 0' >/dev/null 2>&1; then return 0; fi
    inf="$(instance_info "$p" "$n" 2>/dev/null || true)"
    case "${inf%%|*}" in
      RUNNING|UNKNOWN) ;;
      "") ;;
      *) debug "$n 状态为 ${inf%%|*}, 停止等待"; return 1 ;;
    esac
    sleep "$READY_INTERVAL"
    waited=$((waited + READY_INTERVAL))
  done
  return 1
}

sync_one_internal() {  # sync_one_internal <项目> <实例> [--wait-ready]
  local p="$1" n="$2" mode="${3:-}"
  local tag="$n"; [ -n "$p" ] && tag="$p/$n"

  if ! evaluate_instance "$p" "$n"; then
    if [ "$mode" = "--wait-ready" ]; then
      if ! wait_ready "$p" "$n"; then err "$tag 等待就绪超时"; return 1; fi
      evaluate_instance "$p" "$n" || { err "$tag 无法探测"; return 1; }
    else
      err "$tag 无法进入(未启动?)"
      return 1
    fi
  fi

  if [ "$EV_STATE" = "OK" ] && [ "$OPT_FORCE" != 1 ]; then
    debug "$tag 时区已一致 ($EV_TZ $EV_OFFSET)"
    return 0
  fi
  info "$tag: 当前=$(state_label "$EV_STATE") [$EV_TZ ${EV_OFFSET:-未知}] → 目标=$HOST_TZ"
  if apply_tz "$p" "$n"; then
    okmsg "$tag 已同步为 $HOST_TZ"
    return 0
  fi
  return 1
}

with_lock() {  # with_lock <锁名> <命令...>
  local name="$1"; shift
  mkdir_p "$STATE_DIR"
  if need_cmd flock; then
    local lockfile="$STATE_DIR/$name.lock" rc=0
    if exec 9>"$lockfile" 2>/dev/null; then
      if ! flock -n 9; then
        debug "$name 已有同步任务在跑, 跳过"
        exec 9>&-
        return 0
      fi
      "$@" || rc=$?
      exec 9>&-
      return "$rc"
    fi
  fi
  "$@"
}

#-------------------------------------------------------------------------------
# 事件守护
#-------------------------------------------------------------------------------
LAST_SWEEP_FILE=""
schedule_sweep() {
  [ -n "$LAST_SWEEP_FILE" ] || LAST_SWEEP_FILE="$STATE_DIR/.last_sweep"
  local now last=0
  now="$(date '+%s')"
  [ -r "$LAST_SWEEP_FILE" ] && last="$(cat "$LAST_SWEEP_FILE" 2>/dev/null || echo 0)"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ "$((now - last))" -lt 15 ] && return 0
  printf '%s' "$now" >"$LAST_SWEEP_FILE" 2>/dev/null || true
  elog "触发全量校准(事件里没有实例名)"
  ( OPT_QUIET=1; run_all_sync ) >>"$LOG_FILE" 2>&1 </dev/null &
}

run_sync_job() {  # 在锁内执行
  local p="$1" n="$2"
  elog "开始同步 $p/$n"
  sync_one_internal "$p" "$n" --wait-ready
}

dispatch_sync() {  # 后台同步一个实例
  local p="$1" n="$2" tag
  tag="$(lock_tag "$p" "$n")"
  mkdir_p "$STATE_DIR"
  (
    with_lock "$tag" run_sync_job "$p" "$n" >>"$LOG_FILE" 2>&1
    elog "同步任务结束 $p/$n"
  ) </dev/null >/dev/null 2>&1 &
}

handle_event_line() {
  local line="$1" action="" name="" proj=""
  case "$line" in
    *'"action":"instance-started"'*) action="started" ;;
    *'"action":"instance-ready"'*)   action="started" ;;
    *'"action":"instance-created"'*) action="created" ;;
    *) return 0 ;;
  esac

  name="$(printf '%s' "$line" | grep -oE '"source":"/1\.0/(instances|virtual-machines)/[^"?]+' | head -n1 | sed -E 's#.*/##')"
  if [ -z "$name" ]; then
    name="$(printf '%s' "$line" | grep -oE '"name":"[^"]+"' | head -n1 | sed -E 's/.*"name":"([^"]+)".*/\1/')"
  fi
  proj="$(printf '%s' "$line" | grep -oE '"project":"[^"]+"' | head -n1 | sed -E 's/.*"project":"([^"]+)".*/\1/')"

  if [ -z "$name" ]; then
    elog "事件里解析不到实例名, 改为全量校准"
    schedule_sweep
    return 0
  fi
  is_ignored "$name" && { debug "忽略 $name (IGNORE_CONTAINERS)"; return 0; }

  case "$action" in
    created)
      elog "捕获实例创建: $name (项目 ${proj:-default}), 预设 environment.TZ=$HOST_TZ"
      set_env_tz_only "$proj" "$name" && elog "$name 的 environment.TZ 已预设" || true
      ;;
    started)
      elog "捕获实例启动: $name (项目 ${proj:-default}), 开始同步时区"
      dispatch_sync "$proj" "$name"
      ;;
  esac
}

foreground_watch() {  # $1: 是否把事件打到终端
  local echo_events="$1" line
  local -a margs=(monitor --type=lifecycle --format=json)
  if [ -z "$OPT_PROJECT" ] && [ "$OPT_ALL_PROJECTS" = 1 ]; then
    if "$INCUS_BIN" monitor --help 2>&1 | grep -q -- '--all-projects'; then
      margs+=(--all-projects)
    fi
  fi
  [ -n "$OPT_PROJECT" ] && margs+=(--project "$OPT_PROJECT")

  elog "启动时先做一次全量校准"
  ( OPT_QUIET=1; run_all_sync ) >>"$LOG_FILE" 2>&1 </dev/null &

  while :; do
    elog "连接 incus monitor: ${margs[*]}"
    [ "$echo_events" = 1 ] && info "已连接 incus 事件流, 等待实例创建/启动事件… (Ctrl-C 退出)"
    "$INCUS_BIN" "${margs[@]}" 2>>"$LOG_FILE" | while IFS= read -r line; do
      [ "$echo_events" = 1 ] && printf '  %s事件%s %s\n' "$C_CYN" "$C_RST" "$line"
      handle_event_line "$line"
    done
    elog "事件流断开, 2 秒后重连"
    [ "$echo_events" = 1 ] && warn "incus 事件流断开, 2 秒后自动重连…"
    sleep 2
  done
}

#-------------------------------------------------------------------------------
# 检测 / 校准
#-------------------------------------------------------------------------------
_drift_str() {
  local d="$1"
  if [ -z "$d" ]; then printf '%s' "-"; return; fi
  if [ "$d" = "0" ]; then printf '%s' "0s"; return; fi
  printf '%s' "${d}s"
}

cmd_check() {
  find_incus || die "找不到 incus 命令"
  require_access check
  load_host_env

  local list
  list="$(list_instances)" || { err "无法列出实例, 请确认 incus 守护进程在运行。"; return 1; }

  local total=0 okc=0 badc=0 skipc=0
  local n p e inf st ty drift label
  printf '%s\n' "================================================================================================"
  printf '%s\n' "宿主机时区: ${C_BLD}${HOST_TZ}${C_RST} (${HOST_ZONE} ${HOST_OFFSET})      宿主机时间: $(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s\n' "================================================================================================"
  printf '%-20s %-8s %-17s %-6s %-19s %-7s %s\n' "INSTANCE" "STATE" "TZ" "OFFSET" "LOCAL-TIME" "DRIFT" "VERDICT"
  printf '%s\n' "------------------------------------------------------------------------------------------------"

  while IFS=$'\t' read -r n p e; do
    [ -n "$n" ] || continue
    total=$((total + 1))
    if is_ignored "$n"; then
      printf '%-20s %-8s %-17s %-6s %-19s %-7s %s\n' "$n" "-" "-" "-" "-" "-" "[忽略]"
      skipc=$((skipc + 1)); continue
    fi
    inf="$(instance_info "$p" "$n" 2>/dev/null || true)"
    st="${inf%%|*}"; ty="${inf#*|}"
    [ -n "$st" ] || st="UNKNOWN"
    [ -n "$ty" ] || ty="container"
    if [ "$st" != "RUNNING" ]; then
      printf '%-20s %-8s %-17s %-6s %-19s %-7s %s\n' "$n" "$st" "-" "-" "-" "-" "[跳过] 未运行"
      skipc=$((skipc + 1)); continue
    fi
    if ! evaluate_instance "$p" "$n"; then
      printf '%-20s %-8s %-17s %-6s %-19s %-7s %s%s%s\n' "$n" "$st" "?" "?" "?" "?" "$C_RED" "无法进入实例" "$C_RST"
      badc=$((badc + 1)); continue
    fi
    drift="$(_drift_str "$EV_DELTA")"
    if [ "$EV_STATE" = "OK" ]; then okc=$((okc + 1)); else badc=$((badc + 1)); fi
    label="$(state_label "$EV_STATE")"
    printf '%-20s %-8s %-17s %-6s %-19s %-7s %s%s%s\n' \
      "$n" "$st" "${EV_TZ:-(未知)}" "${EV_OFFSET:-?}" "${EV_DATE:-?}" "$drift" \
      "$(state_color "$EV_STATE")" "$label" "$C_RST"
    if [ "$EV_STATE" != "OK" ]; then
      printf '%s\n' "                     └─ $EV_NOTE"
    fi
    case "$ty" in
      virtual-machine*)
        printf '%s\n' "                     └─ 这是虚拟机($ty): 时钟独立于宿主机, 若 DRIFT 不为 0 请在该虚拟机内启用 NTP" ;;
    esac
    if [ "$SET_ENV_TZ" = 1 ] && [ -n "$e" ] && [ "$e" != "$HOST_TZ" ]; then
      printf '%s\n' "                     └─ incus 配置 environment.TZ=$e (与宿主机不同, 校准时会一并修正)"
    fi
  done <<<"$list"

  printf '%s\n' "------------------------------------------------------------------------------------------------"
  if [ "$total" = "0" ]; then
    warn "没有发现任何实例(检查 --project 或 incus 配置)。"
    return 0
  fi
  printf '%s\n' "共 $total 个实例: 一致 $okc, 需处理 $badc, 未运行/忽略 $skipc"
  if [ "$badc" -gt 0 ]; then
    info "执行 '${0##*/} sync-all' 一键校准, 或 '${0##*/} sync <实例名>' 校准单个"
  else
    okmsg "所有运行中的实例时区都与宿主机一致"
  fi
  [ "$badc" -gt 0 ] && return 1
  return 0
}

run_all_sync() {
  find_incus || die "找不到 incus 命令"
  require_access sync-all
  load_host_env

  local list
  list="$(list_instances)" || { err "无法列出实例, 请确认 incus 守护进程在运行。"; return 1; }

  local total=0 fixed=0 okc=0 failc=0 skipc=0
  local n p e inf tag
  info "宿主机时区: $HOST_TZ ($HOST_OFFSET), 开始对齐所有运行中的实例…"
  while IFS=$'\t' read -r n p e; do
    [ -n "$n" ] || continue
    total=$((total + 1))
    if is_ignored "$n"; then debug "忽略 $n"; skipc=$((skipc + 1)); continue; fi
    inf="$(instance_info "$p" "$n" 2>/dev/null || true)"
    if [ "${inf%%|*}" != "RUNNING" ]; then
      debug "$n 未运行, 跳过(每次启动时守护会自动同步)"
      skipc=$((skipc + 1)); continue
    fi
    tag="$n"; [ -n "$p" ] && tag="$p/$n"
    if ! evaluate_instance "$p" "$n"; then
      warn "$tag 无法探测, 跳过"
      failc=$((failc + 1)); continue
    fi
    if [ "$EV_STATE" = "OK" ] && [ "$OPT_FORCE" != 1 ]; then
      debug "$tag 已一致"
      okc=$((okc + 1)); continue
    fi
    info "$tag: 当前=$(state_label "$EV_STATE") [$EV_TZ ${EV_OFFSET:-未知}] → 目标=$HOST_TZ"
    if apply_tz "$p" "$n"; then
      okmsg "$tag 已同步为 $HOST_TZ"
      fixed=$((fixed + 1))
    else
      err "$tag 同步失败"
      failc=$((failc + 1))
    fi
  done <<<"$list"

  printf '%s\n' "------------------------------------------------------------"
  printf '%s\n' "实例总数 $total | 本来就一致 $okc | 本次修正 $fixed | 失败 $failc | 跳过(未运行/忽略) $skipc"
  [ "$failc" -gt 0 ] && return 1
  return 0
}

cmd_sync() {  # cmd_sync <名称> [项目]
  local n="${1:-}" p="${2:-$OPT_PROJECT}"
  find_incus || die "找不到 incus 命令"
  require_access sync
  load_host_env
  [ -n "$n" ] || die "用法: ${0##*/} sync <实例名>"

  local inf
  inf="$(instance_info "$p" "$n" 2>/dev/null || true)"
  if [ -z "$inf" ]; then
    err "找不到实例 $n (可用 '${0##*/} check' 查看全部实例)"
    return 1
  fi
  if [ "${inf%%|*}" != "RUNNING" ]; then
    err "实例 $n 当前状态是 ${inf%%|*}, 未运行。启动后守护会自动同步, 也可启动后再执行本命令。"
    return 1
  fi
  if evaluate_instance "$p" "$n"; then
    if [ "$EV_STATE" = "OK" ] && [ "$OPT_FORCE" != 1 ]; then
      okmsg "$n 时区已一致 ($EV_TZ $EV_OFFSET), 无需修改"
      return 0
    fi
    info "$n: 当前=$(state_label "$EV_STATE") [$EV_TZ ${EV_OFFSET:-未知}] → 目标=$HOST_TZ"
  fi
  if apply_tz "$p" "$n"; then
    okmsg "$n 已同步为 $HOST_TZ"
    return 0
  fi
  return 1
}

#-------------------------------------------------------------------------------
# 安装 / 卸载 / 状态
#-------------------------------------------------------------------------------
write_units() {
  mkdir_p /etc/systemd/system
  cat >"/etc/systemd/system/$UNIT_SERVICE" <<EOF
[Unit]
Description=Incus instance timezone sync daemon (incus-tz-sync)
After=network-online.target incus.service

[Service]
Type=simple
ExecStart=$BIN_PATH daemon
Restart=always
RestartSec=3
Nice=5

[Install]
WantedBy=multi-user.target
EOF
  cat >"/etc/systemd/system/$UNIT_RECONCILE" <<EOF
[Unit]
Description=Incus instance timezone full reconcile (incus-tz-sync)

[Service]
Type=oneshot
ExecStart=$BIN_PATH sync-all --quiet
EOF
  cat >"/etc/systemd/system/$UNIT_TIMER" <<EOF
[Unit]
Description=Periodic Incus instance timezone reconcile (incus-tz-sync)

[Timer]
OnBootSec=90s
OnUnitActiveSec=$TIMER_INTERVAL
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
}

cmd_install() {
  require_root install
  find_incus || die "找不到 incus 命令"
  [ -r "$SELF_PATH" ] || die "无法读取脚本自身, 请先把脚本保存为文件再执行 install。"

  # 先落配置文件: 万一后面时区探测失败, 用户至少有个文件可以编辑修正
  if [ ! -f "$CONF_FILE" ]; then
    cat >"$CONF_FILE" <<EOF
# incus-tz-sync 配置文件(由 $BIN_PATH 读取, 语法为 shell 赋值)
# 修改后需重启服务: systemctl restart $UNIT_SERVICE

# 强制指定宿主机时区(留空=自动探测)
HOST_TZ_OVERRIDE=""

# 只处理指定 incus 项目(留空=所有项目)
DEFAULT_PROJECT=""

# 忽略这些实例, 逗号分隔, 支持通配: "router-*,test"
IGNORE_CONTAINERS=""

# 同时写 incus 配置 environment.TZ(让容器内进程一开始就带正确时区)
SET_ENV_TZ=1

# 偏移相同但时区名不同时也强制改成与宿主机同名
ENFORCE_NAME=1

# 容器缺 tzdata 时是否允许在容器内装包(默认 0: 直接从宿主机拷贝 zoneinfo, 不需要容器联网)
TZ_DATA_INSTALL=0

# 等待新实例可执行命令的最长秒数
READY_TIMEOUT=120

# 兜底定时器周期
TIMER_INTERVAL=15min

# install 时创建的快捷命令(直接输入它进菜单; 留空=不创建)
MENU_COMMAND=$MENU_COMMAND

LOG_FILE=$LOG_FILE
EOF
    info "已生成配置文件 $CONF_FILE"
  fi

  load_host_env
  mkdir_p /usr/local/bin

  # 已经在目标位置时不能再 install 复制: 源和目标其实是同一个文件, install 会报 same file
  local self_real bin_real
  self_real="$(readlink -f "$SELF_PATH" 2>/dev/null || printf '%s' "$SELF_PATH")"
  bin_real="$(readlink -f "$BIN_PATH" 2>/dev/null || printf '%s' "$BIN_PATH")"
  if [ "$self_real" = "$bin_real" ]; then
    info "脚本已经在 $BIN_PATH, 跳过复制"
  else
    install -m 0755 "$SELF_PATH" "$BIN_PATH" || die "安装到 $BIN_PATH 失败"
  fi
  okmsg "已安装脚本: $BIN_PATH"

  if [ -n "$MENU_COMMAND" ]; then
    if valid_command_name "$MENU_COMMAND"; then
      mkdir_p /usr/local/bin
      if ln -sf "$BIN_PATH" "/usr/local/bin/$MENU_COMMAND"; then
        okmsg "已创建快捷命令: $MENU_COMMAND   (以后敲 $MENU_COMMAND 直接进菜单)"
      else
        warn "创建快捷命令 $MENU_COMMAND 失败, 可手动执行: ln -sf $BIN_PATH /usr/local/bin/$MENU_COMMAND"
      fi
    else
      warn "MENU_COMMAND 含非法字符, 已跳过快捷命令创建: $MENU_COMMAND"
    fi
  fi

  if ! need_cmd systemctl; then
    warn "本机没有 systemd, 无法自动开机自启。可用 crontab 兜底:"
    printf '  */5 * * * * %s sync-all --quiet\n' "$BIN_PATH"
    return 0
  fi

  write_units
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable "$UNIT_SERVICE" >/dev/null 2>&1 || true
  # 用 restart 而不是 enable --now: 更新脚本后重跑 install 时, 已在运行的守护也要换成新代码
  if systemctl restart "$UNIT_SERVICE" >/dev/null 2>&1; then
    okmsg "事件守护已启用/重启: $UNIT_SERVICE (新实例创建/启动时立即同步)"
  else
    err "启动 $UNIT_SERVICE 失败, 请查看: systemctl status $UNIT_SERVICE"
  fi
  if [ "$OPT_NO_TIMER" = 1 ]; then
    info "按要求未安装兜底定时器"
  else
    systemctl enable "$UNIT_TIMER" >/dev/null 2>&1 || true
    if systemctl restart "$UNIT_TIMER" >/dev/null 2>&1; then
      okmsg "兜底定时器已启用/重启: $UNIT_TIMER (每 $TIMER_INTERVAL 全量校准一次)"
    else
      warn "启动 $UNIT_TIMER 失败(不影响事件守护)"
    fi
  fi
  printf '\n'
  info "查看状态: systemctl status $UNIT_SERVICE"
  info "实时日志: journalctl -u $UNIT_SERVICE -f   或   tail -f $LOG_FILE"
}

cmd_uninstall() {
  require_root uninstall
  if need_cmd systemctl; then
    systemctl disable --now "$UNIT_TIMER" >/dev/null 2>&1 || true
    systemctl disable --now "$UNIT_SERVICE" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$UNIT_SERVICE" "/etc/systemd/system/$UNIT_RECONCILE" "/etc/systemd/system/$UNIT_TIMER"
    systemctl daemon-reload >/dev/null 2>&1 || true
    okmsg "已停止并移除 systemd 服务与定时器"
  fi
  if [ -f "$BIN_PATH" ]; then
    rm -f "$BIN_PATH" && okmsg "已删除 $BIN_PATH"
  fi
  if [ -n "$MENU_COMMAND" ] && valid_command_name "$MENU_COMMAND" && [ -L "/usr/local/bin/$MENU_COMMAND" ]; then
    rm -f "/usr/local/bin/$MENU_COMMAND" && okmsg "已删除快捷命令 $MENU_COMMAND"
  fi
  info "配置文件 $CONF_FILE 与日志 $LOG_FILE 已保留, 需要可手动删除。"
}

cmd_status() {
  printf '%s\n' "incus-tz-sync v$SCRIPT_VERSION"
  local tz
  if tz="$(detect_host_tz 2>/dev/null)"; then
    printf '%-12s %s (%s %s)\n' "宿主机时区" "$tz" "$(date '+%Z')" "$(date '+%z')"
  else
    printf '%-12s %s\n' "宿主机时区" "无法识别"
  fi
  printf '%-12s %s\n' "脚本位置" "$SELF_PATH"
  printf '%-12s %s\n' "配置文件" "$CONF_FILE $([ -r "$CONF_FILE" ] && printf '(存在)' || printf '(未创建)')"
  printf '%-12s %s\n' "日志文件" "$LOG_FILE"
  if find_incus; then
    printf '%-12s %s\n' "incus 命令" "$INCUS_BIN"
    local cnt=0 n p e
    while IFS=$'\t' read -r n p e; do [ -n "$n" ] && cnt=$((cnt + 1)); done < <(list_instances 2>/dev/null) || true
    printf '%-12s %s\n' "实例数量" "$cnt"
  else
    printf '%-12s %s\n' "incus 命令" "未找到"
  fi
  if need_cmd systemctl; then
    printf '%-12s %s\n' "事件守护" "$(systemctl is-active "$UNIT_SERVICE" 2>/dev/null || echo '未启用')"
    printf '%-12s %s\n' "兜底定时器" "$(systemctl is-active "$UNIT_TIMER" 2>/dev/null || echo '未启用')"
  fi
}

cmd_log() {
  if [ -r "$LOG_FILE" ]; then tail -n 40 "$LOG_FILE"; else err "日志文件不存在: $LOG_FILE"; return 1; fi
}

#-------------------------------------------------------------------------------
# 交互菜单
#-------------------------------------------------------------------------------
_pause() { [ -t 0 ] && { read -r -p "按回车返回菜单…" _ || true; }; return 0; }

menu_pick_instance() {  # 输出 "项目<TAB>名称"
  local -a names=() projs=()
  local n p e i=0
  while IFS=$'\t' read -r n p e; do
    [ -n "$n" ] || continue
    if is_running "$p" "$n"; then names+=("$n"); projs+=("$p"); fi
  done < <(list_instances)
  if [ "${#names[@]}" = "0" ]; then warn "没有运行中的实例。"; return 1; fi
  printf '%s\n' "运行中的实例:"
  for i in "${!names[@]}"; do
    printf '  %2d) %s%s\n' "$((i + 1))" "${names[$i]}" "${projs[$i]:+ (项目 ${projs[$i]})}"
  done
  printf '%s' "请输入序号(或直接输入实例名, 直接回车取消): "
  local ans
  read -r ans || return 1
  [ -n "$ans" ] || return 1
  case "$ans" in
    *[!0-9]*)
      printf '%s\t%s\n' "$OPT_PROJECT" "$ans"; return 0 ;;
    *)
      local idx=$((ans - 1))
      if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#names[@]}" ]; then warn "序号超出范围"; return 1; fi
      printf '%s\t%s\n' "${projs[$idx]}" "${names[$idx]}"; return 0 ;;
  esac
}

cmd_menu() {
  if [ ! -t 0 ]; then usage; return 0; fi
  local choice svc timer cnt picked proj name
  while :; do
    svc="未启用"; timer="未启用"
    if need_cmd systemctl; then
      svc="$(systemctl is-active "$UNIT_SERVICE" 2>/dev/null || echo 未启用)"
      timer="$(systemctl is-active "$UNIT_TIMER" 2>/dev/null || echo 未启用)"
    fi
    cnt=0
    if find_incus; then
      while IFS=$'\t' read -r n p e; do [ -n "$n" ] && cnt=$((cnt + 1)); done < <(list_instances 2>/dev/null) || true
    fi
    printf '\n%s\n' "${C_BLD}============= incus-tz-sync v$SCRIPT_VERSION =============${C_RST}"
    printf ' 宿主机时区 : %s (%s %s)\n' "$(detect_host_tz 2>/dev/null || echo 未知)" "$(date '+%Z')" "$(date '+%z')"
    printf ' 当前时间   : %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf ' 实例数量   : %s\n' "$cnt"
    printf ' 事件守护   : %s      兜底定时器: %s\n' "$svc" "$timer"
    printf '%s\n' "---------------------------------------------------------"
    printf '%s\n' " 1) 一键检测所有实例的时区与时间"
    printf '%s\n' " 2) 一键校准所有实例的时区"
    printf '%s\n' " 3) 校准单个实例的时区"
    printf '%s\n' " 4) 安装/启用「新建实例立即同步」(systemd 服务+定时器)"
    printf '%s\n' " 5) 卸载 systemd 服务与定时器"
    printf '%s\n' " 6) 查看守护日志(最后 40 行)"
    printf '%s\n' " 7) 帮助"
    printf '%s\n' " 0) 退出"
    printf '%s' "请选择: "
    read -r choice || break
    case "$choice" in
      1) cmd_check; _pause ;;
      2) run_all_sync; _pause ;;
      3)
        picked="$(menu_pick_instance)" || { _pause; continue; }
        proj="${picked%%$'\t'*}"; name="${picked#*$'\t'}"
        [ -n "$name" ] && cmd_sync "$name" "$proj"
        _pause ;;
      4) cmd_install; _pause ;;
      5) cmd_uninstall; _pause ;;
      6) cmd_log; _pause ;;
      7) usage; _pause ;;
      0|q|Q|exit) break ;;
      *) warn "无效选择: $choice" ;;
    esac
  done
}

#-------------------------------------------------------------------------------
# 入口
#-------------------------------------------------------------------------------
load_conf() {
  if [ -r "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONF_FILE" || warn "读取 $CONF_FILE 失败, 使用内置默认值"
  fi
}

main() {
  load_conf

  local cmd="" seencmd=0 a
  local -a rest=() pos=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -q|--quiet)   OPT_QUIET=1 ;;
      -n|--dry-run) OPT_DRY_RUN=1 ;;
      -f|--force)   OPT_FORCE=1 ;;
      -v|--verbose) OPT_VERBOSE=1 ;;
      -h|--help)    usage; return 0 ;;
      -V|--version) printf '%s\n' "$SCRIPT_VERSION"; return 0 ;;
      --no-timer)   OPT_NO_TIMER=1 ;;
      --project)    shift; OPT_PROJECT="${1:-}" ;;
      --project=*)  OPT_PROJECT="${1#*=}" ;;
      --all-projects) OPT_ALL_PROJECTS=1 ;;
      --) shift; while [ $# -gt 0 ]; do rest+=("$1"); shift; done; break ;;
      -*) err "未知选项: $1"; usage; return 2 ;;
      *) if [ "$seencmd" = "0" ]; then cmd="$1"; seencmd=1; else rest+=("$1"); fi ;;
    esac
    shift
  done

  # 命令后面的全局选项也要生效, 例如 sync-all --quiet
  if [ "${#rest[@]}" -gt 0 ]; then
    for a in "${rest[@]}"; do
      case "$a" in
        -q|--quiet)   OPT_QUIET=1 ;;
        -n|--dry-run) OPT_DRY_RUN=1 ;;
        -f|--force)   OPT_FORCE=1 ;;
        -v|--verbose) OPT_VERBOSE=1 ;;
        --no-timer)   OPT_NO_TIMER=1 ;;
        --project=*)  OPT_PROJECT="${a#*=}" ;;
        -*) : ;;
        *) pos+=("$a") ;;
      esac
    done
  fi

  [ -n "$OPT_PROJECT" ] || OPT_PROJECT="${DEFAULT_PROJECT:-}"
  if [ -z "$OPT_PROJECT" ]; then OPT_ALL_PROJECTS=1; else OPT_ALL_PROJECTS=0; fi

  case "${cmd:-menu}" in
    menu|"")   cmd_menu ;;
    check)     cmd_check ;;
    sync-all|syncall|fix-all) run_all_sync ;;
    sync|fix)  cmd_sync "${pos[0]:-}" ;;
    watch)     find_incus || die "找不到 incus 命令"; require_access watch; load_host_env; foreground_watch 1 ;;
    daemon)    find_incus || die "找不到 incus 命令"; require_access daemon; load_host_env; foreground_watch 0 ;;
    install)   cmd_install ;;
    uninstall) cmd_uninstall ;;
    status)    cmd_status ;;
    log|logs)  cmd_log ;;
    help)      usage ;;
    *)         err "未知命令: $cmd"; usage; return 2 ;;
  esac
}

main "$@"
