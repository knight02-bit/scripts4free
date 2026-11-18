#!/usr/bin/env bash
# ============================================================================
# sysmon.sh —— 单机资源快照：CPU / 内存 / GPU / 占用最高的进程（含容器归属）
#
# 用法:
#   ./sysmon.sh                 默认 Top 8
#   ./sysmon.sh 12              Top 12
#   ./sysmon.sh 8 --watch 5     每 5 秒刷新（Ctrl-C 退出）
#   ./sysmon.sh --no-color      纯文本（重定向时自动关闭颜色）
#   ./sysmon.sh --no-docker     跳过容器段（省 2 秒）
#   ./sysmon.sh 10 > snap.txt   存快照
#
# 说明:
#   * CPU% 取 top 第二次采样的瞬时值；若 top 缺失/格式不认识，自动退化为 ps 平均值并注明
#   * 进程若在容器里，标出 容器名 + 容器工作目录 + 宿主机挂载源路径（docker / podman 自动识别）
#   * 依赖: bash4+ / procps(ps,top) / awk。nvidia-smi、docker|podman 均为可选，缺失自动降级
#   * 适配: 任意 Linux（cgroup v1/v2、rootless 容器）；不支持 macOS/Windows 原生（无 /proc）
# ============================================================================
set -uo pipefail
export LC_NUMERIC=C          # 防止某些 locale 下小数点是逗号导致数值解析错乱

TOP_N=8
WATCH=0
COLOR=auto
NO_DOCKER=0
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
  a="${args[$i]}"
  case "$a" in
    --watch)      WATCH="${args[$((i+1))]:-5}"; i=$((i+1)) ;;
    --watch=*)    WATCH="${a#*=}" ;;
    --no-color)   COLOR=never ;;
    --color)      COLOR=always ;;
    --no-docker)  NO_DOCKER=1 ;;
    -V|--version) echo "sysmon.sh 1.2"; exit 0 ;;
    -h|--help)    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    ''|*[!0-9]*)  ;;
    *)            TOP_N="$a" ;;
  esac
  i=$((i+1))
done

# 容器运行时：docker 优先，podman 次之（两者 inspect/stats 模板基本一致）
RT=""
if command -v docker >/dev/null 2>&1; then RT=docker
elif command -v podman >/dev/null 2>&1; then RT=podman; fi

# ps 是否支持 etimes（GNU/procps 支持；BusyBox/旧版不支持）
PS_ETIMES=1
ps -eo etimes >/dev/null 2>&1 || PS_ETIMES=0

if [ "$COLOR" = always ] || { [ "$COLOR" = auto ] && [ -t 1 ]; }; then
  B=$'\033[1m'; D=$'\033[2m'; Z=$'\033[0m'
  CY=$'\033[36m'; YL=$'\033[33m'; GN=$'\033[32m'; RD=$'\033[31m'; MG=$'\033[35m'
else
  B=; D=; Z=; CY=; YL=; GN=; RD=; MG=
fi

# ---------------------------------------------------------------- 小工具 ----
hr()  { printf '%s\n' "${D}──────────────────────────────────────────────────────────────────────────────${Z}"; }
sec() { printf '\n%s%s%s\n' "$B$CY" "$*" "$Z"; }
human() { awk -v b="${1:-0}" 'BEGIN{split("B KiB MiB GiB TiB",u," ");i=1;while(b>=1024&&i<5){b/=1024;i++}
  if(i==1) printf "%d %s", b, u[i]; else printf "%.1f %s", b, u[i]}'; }
pctc() { # $1=百分比数值 → 带色、定宽 6
  awk -v v="${1:-0}" -v g="$GN" -v y="$YL" -v r="$RD" -v z="$Z" 'BEGIN{
    c=(v>=85)?r:((v>=60)?y:g); printf "%s%5.1f%%%s", c, v, z }'
}
fmt_time() { awk -v s="${1:-0}" 'BEGIN{
    d=int(s/86400); h=int((s%86400)/3600); m=int((s%3600)/60);
    if(d>0) printf "%dd%dh", d, h;
    else if(h>0) printf "%dh%02dm", h, m;
    else printf "%dm", m }'
}

# ------------------------------------------------------- 容器索引 ----
declare -A DK_NAME DK_IMG DK_WD DK_MNT
docker_init() {
  [ -n "$RT" ] || return 0
  local ids id name img wd mnt
  ids=$("$RT" ps -q 2>/dev/null) || return 0
  [ -z "$ids" ] && return 0
  while IFS='|' read -r id name img wd mnt; do
    [ -z "${id:-}" ] && continue
    id="${id:0:12}"
    mnt=$(printf '%s' "$mnt" | tr ' ' '\n' | sort | tr '\n' ' ')   # 稳定排序
    DK_NAME[$id]="${name#/}"; DK_IMG[$id]="$img"; DK_WD[$id]="$wd"; DK_MNT[$id]="$mnt"
  done < <(printf '%s\n' "$ids" | xargs "$RT" inspect \
            --format '{{.Id}}|{{.Name}}|{{.Config.Image}}|{{.Config.WorkingDir}}|{{range .Mounts}}{{.Source}}->{{.Destination}} {{end}}' 2>/dev/null)
}

pid_cid() { # pid → 12 位容器 id（不在容器里则失败）。cgroup v1(`/docker/<id>`) 与 v2(`docker-<id>.scope`) 都覆盖
  local cg cid
  cg=$(cat "/proc/$1/cgroup" 2>/dev/null) || return 1
  cid=$(printf '%s' "$cg" | grep -oE '[0-9a-f]{64}' | head -1)
  [ -z "$cid" ] && return 1
  cid="${cid:0:12}"
  [ -n "${DK_NAME[$cid]:-}" ] || return 1
  printf '%s' "$cid"
}

describe() { # pid → 归属字符串
  local cid wd mnt m parts="" n=0
  if cid=$(pid_cid "$1"); then
    wd="${DK_WD[$cid]:-}"; mnt="${DK_MNT[$cid]:-}"
    for m in $mnt; do
      n=$((n+1)); [ "$n" -le 2 ] && parts="$parts${parts:+ · }${m%%->*}"
    done
    [ -z "$parts" ] && parts="镜像 ${DK_IMG[$cid]:-?}"
    printf '%s⚙ %s%s %s%s%s %s↔ %s%s' "$MG" "${DK_NAME[$cid]}" "$Z" \
      "$D" "${wd:-/}" "$Z" "$D" "$parts" "$Z"
  else
    printf '%s[宿主]%s' "$D" "$Z"
  fi
}

ps_details() { # pid → "user pmem rss etimes(或 -)"
  if [ "$PS_ETIMES" = 1 ]; then
    ps -o user=,pmem=,rss=,etimes= -p "$1" 2>/dev/null
  else
    printf '%s -' "$(ps -o user=,pmem=,rss= -p "$1" 2>/dev/null)"
  fi
}

print_row() { # $1=pid  $2=CPU%（空则取 ps 平均值）
  local pid="$1" cpu="${2:-}" user pmem rss et cmd d disp
  d=$(ps_details "$pid"); [ -z "$d" ] && return 1
  read -r user pmem rss et <<<"$d"
  [ -z "$cpu" ] && cpu=$(ps -o pcpu= -p "$pid" 2>/dev/null | tr -d ' ')
  [ -z "$cpu" ] && cpu=0
  [ -z "$rss" ] && rss=0
  cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-88)
  [ -z "$cmd" ] && cmd=$(ps -o comm= -p "$pid" 2>/dev/null)
  if [ "$et" = "-" ]; then disp="—"; else disp=$(fmt_time "$et"); fi
  printf '  %-8s %-9s %s %s %-9s %-8s %s\n' \
    "$pid" "${user:0:9}" "$(pctc "$cpu")" "$(pctc "$pmem")" \
    "$(human $((rss*1024)))" "$disp" "$cmd"
  printf '           %s↳ %s%s\n' "$D" "$(describe "$pid")" "$Z"
}

# ------------------------------------------------------------- 各区块 ----
mem_section() {
  local t a buf cac st sf used avail
  t=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
  a=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
  buf=$(awk '/^Buffers:/{print $2}' /proc/meminfo)
  cac=$(awk '/^Cached:/{print $2}' /proc/meminfo)
  st=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
  sf=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
  used=$(( (t - a) / 1024 )); avail=$(( a / 1024 )); t=$(( t / 1024 ))
  st=$(( st / 1024 )); sf=$(( sf / 1024 ))
  local cache=$(( (buf + cac) / 1024 ))
  printf '  %-8s %s  已用 %s / %s (%s)   可用 %s\n' \
    "总内存" "$(human $((t*1024*1024)))" "$(human $((used*1024*1024)))" \
    "$(human $((t*1024*1024)))" \
    "$(pctc "$(awk -v u=$used -v t=$t 'BEGIN{printf "%.1f", t?u*100/t:0}')")" \
    "$(human $((avail*1024*1024)))"
  printf '  %-8s %s   swap 已用 %s / %s\n' "缓存" "$(human $((cache*1024*1024)))" \
    "$(human $(((st-sf)*1024*1024)))" "$(human $((st*1024*1024)))"
}

gpu_section() {
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    printf '  %s未检测到 nvidia-smi（无 NVIDIA GPU 或驱动未装）%s\n' "$D" "$Z"; return
  fi
  local idx name mu mt util temp pw pl fan
  printf '  %-3s %-16s  %-17s  %-7s  %-6s  %-12s  %s\n' "GPU" "型号" "显存 已用/总 MiB" "利用率" "温度" "功耗 W" "风扇"
  while IFS=',' read -r idx name mu mt util temp pw pl fan; do
    idx=$(echo "$idx"|tr -d ' '); name=$(echo "$name"|sed 's/^ *//;s/ *$//;s/NVIDIA GeForce //')
    mu=$(echo "$mu"|tr -d ' '); mt=$(echo "$mt"|tr -d ' '); util=$(echo "$util"|tr -d ' ')
    temp=$(echo "$temp"|tr -d ' '); pw=$(echo "$pw"|tr -d ' '); pl=$(echo "$pl"|tr -d ' '); fan=$(echo "$fan"|tr -d ' ')
    local memcol powc free_mib
    memcol=$(printf '%7s / %-7s' "$mu" "$mt")
    powc=$(printf '%s / %s' "$(awk -v p="$pw" 'BEGIN{printf "%.0f", p}')" "$(awk -v p="$pl" 'BEGIN{printf "%.0f", p}')")
    free_mib=$(awk -v t="$mt" -v u="$mu" 'BEGIN{printf "%.0f", t-u}')
    printf '  %-3s %-16s  %-17s  %-7s  %-6s  %-12s  %s%%\n' \
      "$idx" "$name" "$memcol" "$(pctc "$util")" "${temp}°C" "$powc" "$fan"
    printf '  %s（显存占用 %s%%，空闲 %s MiB）%s\n' \
      "$D" "$(awk -v t="$mt" -v u="$mu" 'BEGIN{printf "%.0f", t?u*100/t:0}')" "$free_mib" "$Z"
  done < <(nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu,temperature.gpu,power.draw,power.limit,fan.speed \
             --format=csv,noheader,nounits 2>/dev/null)

  local gpid gname gmem
  local -a glines=()
  while IFS=',' read -r gpid gname gmem; do
    gpid=$(echo "$gpid"|tr -d ' '); [ -z "$gpid" ] && continue
    gname=$(echo "$gname"|sed 's/^ *//;s/ *$//'); gmem=$(echo "$gmem"|tr -d ' ')
    glines+=("  $(printf '%-8s' "$gpid") $(printf '%7s' "${gmem} MiB")  $(describe "$gpid")  ${D}${gname:0:60}${Z}")
  done < <(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null)
  if [ ${#glines[@]} -eq 0 ]; then
    printf '  %sGPU 上无进程（显存空闲）%s\n' "$D" "$Z"
  else
    printf '\n  %s显存占用进程:%s\n' "$B" "$Z"
    printf '%s\n' "${glines[@]}"
  fi
}

top_header() {
  printf '  %-8s %-9s %6s %6s %-9s %-8s %s\n' "PID" "USER" "CPU%" "MEM%" "RSS" "运行" "命令 / 归属"
}

top_cpu() {
  local raw note="" pids pid cpu
  raw=$(top -bn2 -d 1 2>/dev/null || true)
  # 按表头定位 PID / %CPU 列号（procps 与 busybox 的列顺序不同，不能写死 $9）
  pids=$(printf '%s\n' "$raw" | awk '
      /^ *PID +/ {
        hdr++
        if (hdr==1) { n=split($0,c," "); for(i=1;i<=n;i++){ if(c[i]=="%CPU"||c[i]=="CPU%") ci=i; if(c[i]=="PID") pi=i } }
      }
      hdr>=2 && pi && ci && ($pi ~ /^[0-9]+$/) { print $pi, $ci }
    ' | sort -k2 -nr | head -n "$TOP_N")
  if [ -z "$pids" ]; then
    note="top 不可用或格式不认识，已退化为 ps 平均 CPU%（非瞬时）"
    pids=$(ps -eo pid,pcpu 2>/dev/null | tail -n +2 | sort -k2 -nr | head -n "$TOP_N")
  fi
  top_header
  [ -n "$note" ] && printf '  %s⚠ %s%s\n' "$YL" "$note" "$Z"
  while read -r pid cpu; do
    [ -z "${pid:-}" ] && continue
    [ -z "${cpu:-}" ] && cpu=""
    print_row "$pid" "$cpu"
  done <<<"$pids"
}

top_mem() {
  top_header
  local pid
  while read -r pid _; do
    [ -z "${pid:-}" ] && continue
    print_row "$pid"
  done < <(ps -eo pid,rss 2>/dev/null | tail -n +2 | sort -k2 -nr | head -n "$TOP_N")
}

docker_section() {
  if [ -z "$RT" ]; then printf '  %s未安装 docker/podman%s\n' "$D" "$Z"; return; fi
  printf '  %-18s %7s %9s  %-24s %s\n' "容器" "CPU%" "内存" "镜像" "工作目录 ↔ 宿主路径"
  "$RT" stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}' 2>/dev/null |
  while IFS='|' read -r cname ccpu cmem cmperp; do
    local cid wd mnt m parts="" n=0
    cid=$("$RT" inspect -f '{{.Id}}' "$cname" 2>/dev/null); cid="${cid:0:12}"
    wd="${DK_WD[$cid]:-}"; mnt="${DK_MNT[$cid]:-}"
    for m in $mnt; do
      n=$((n+1)); [ "$n" -le 3 ] && parts="$parts${parts:+ · }${m%%->*}"
    done
    printf '  %-18s %7s %9s  %-24s %s%s%s %s%s%s\n' \
      "$cname" "${ccpu%\%}" "$(echo "$cmem"|awk '{print $1}')" \
      "${DK_IMG[$cid]:-?}" "$D" "${wd:-/}" "$Z" "$D" "${parts:-（无挂载）}" "$Z"
  done
}

render() {
  local host now load nproc lp
  host=$(hostname); now=$(date '+%Y-%m-%d %H:%M:%S')
  read -r load _ < /proc/loadavg
  nproc=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
  lp=$(awk -v l="$load" -v n="$nproc" 'BEGIN{printf "%.1f", l*100/n}')
  printf '%s%s @ %s%s\n' "$B" "$host" "$now" "$Z"
  hr
  printf '  %-8s %s   %s\n' "负载" "$load" "($nproc 线程 → $(pctc "$lp"))"
  printf '  %-8s %s\n' "运行" "$(fmt_time "$(cut -d. -f1 /proc/uptime)")"

  sec "① 内存"
  mem_section

  sec "② GPU"
  gpu_section

  sec "③ 占用最高进程（CPU 瞬时）"
  top_cpu

  sec "④ 占用最高进程（内存）"
  top_mem

  if [ "$NO_DOCKER" = 0 ]; then
    sec "⑤ 容器"
    docker_section
  fi

  hr
  printf '%s数据来源: /proc/{meminfo,loadavg,cgroup} · top/ps · nvidia-smi · %s stats%s\n' "$D" "${RT:-容器}" "$Z"
}

docker_init
if [ "${WATCH:-0}" -gt 0 ] 2>/dev/null; then
  while :; do clear; render; printf '\n%s每 %ss 刷新，Ctrl-C 退出%s\n' "$D" "$WATCH" "$Z"; sleep "$WATCH"; done
else
  render
fi
