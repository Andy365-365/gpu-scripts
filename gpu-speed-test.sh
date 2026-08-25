#!/usr/bin/env bash
#
# gpu-speed.sh
#
# 布局：
#   左上：nvidia-smi，每 1 秒刷新
#   左下：gpu_burn -d 0,1
#   右侧：PCIe LnkSta 监控，整列
#
# 功能：
#   1. 根据 GPU_KEYWORD="3090" 自动查找并确认显卡信息。
#   2. 如果没有安装 tmux，则自动尝试安装 tmux，并给出提示。
#   3. 使用独立 tmux socket，不影响系统已有 tmux。
#   4. 在 tmux 中绑定 Ctrl+C -> kill-server，尽量保证单 Ctrl+C 全部退出。
#   5. 如果 tmux 不可用，则自动退回同窗口交替输出模式。
#   6. 修正 SLOT 检测：
#        SLOT_OVERRIDES 手动映射
#        /sys/bus/pci/slots
#        PCI 上游 bridge
#        lspci Physical Slot
#
# 建议直接 root 运行：
#   ./gpu-speed.sh
#
# 或：
#   sudo ./gpu-speed.sh
#

set -u

# ========================= 配置区 =========================

# 显卡查找关键词。
# 默认查找包含 3090 的显卡。
# 如果不想自动查找，可以设置为空：
#   GPU_KEYWORD=""
GPU_KEYWORD="${GPU_KEYWORD:-3090}"

# gpu_burn 所在目录。
# 如果路径不是 $HOME/gpu-burn，请修改这里，或运行时指定：
#   GPU_BURN_DIR=/root/gpu-burn ./gpu-speed.sh
GPU_BURN_DIR="${GPU_BURN_DIR:-$HOME/gpu-burn}"

# gpu_burn 可执行文件。
GPU_BURN_BIN="${GPU_BURN_BIN:-./gpu_burn}"

# gpu_burn 参数。
GPU_BURN_ARGS=(-d 0,1)

# nvidia-smi 刷新间隔，单位秒。
NVIDIA_SMI_INTERVAL=1

# nvidia-smi 是否清屏刷新。
# 1：清屏刷新，类似 watch
# 0：追加输出
NVIDIA_SMI_CLEAR=1

# nvidia-smi 参数。
# 默认使用完整 nvidia-smi 输出。
#
# 如果觉得完整输出太长，可以改成精简输出，例如：
# NVIDIA_SMI_ARGS=(
#   --query-gpu=index,name,temperature.gpu,utilization.gpu,memory.used,memory.total,power.draw
#   --format=csv,noheader
# )
NVIDIA_SMI_ARGS=()

# 手动设备列表。
# 当 GPU_KEYWORD="" 时使用。
# 示例：
# DEVICES=(
#   "04:00.0|6"
#   "84:00.0|7"
# )
DEVICES=()

# 手动 BDF -> SLOT 强制映射，优先级最高。
# 如果自动识别的 SLOT 错误，请在这里填写实际槽位。
# 示例：
# SLOT_OVERRIDES=(
#   "03:00.0|6"
#   "84:00.0|7"
# )
SLOT_OVERRIDES=()

# PCIe LnkSta 刷新间隔，单位秒。
INTERVAL=1

# 是否输出 ---- 分隔线。
# 1 输出，0 不输出。
SHOW_SEPARATOR=1

# 是否优先使用 tmux。
# 1 使用，0 不使用。
USE_TMUX=1

# 如果 tmux 未安装，是否自动安装。
# 1 自动安装，0 不自动安装。
AUTO_INSTALL_TMUX=1

# 右侧 LnkSta 监控窗口宽度。
# 可以写百分比，也可以写列数。
# 例如：
#   TMUX_RIGHT_PANE_WIDTH="50%"
#   TMUX_RIGHT_PANE_WIDTH=80
TMUX_RIGHT_PANE_WIDTH="${TMUX_RIGHT_PANE_WIDTH:-50%}"

# =========================================================

SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"

GPU_CHILD=""
GPU_PID=""
MON_PID=""
NVIDIA_PID=""
MONITOR_SLEEP_PID=""
NVIDIA_SLEEP_PID=""

session_kill() {
  if [[ -n "${GPU_SPEED_TMUX_SOCKET:-}" ]] && command -v tmux >/dev/null 2>&1; then
    tmux -L "$GPU_SPEED_TMUX_SOCKET" kill-server 2>/dev/null || true
  fi
}

die() {
  echo "[!] $*" >&2
  session_kill
  exit 1
}

kill_tree() {
  local pid="${1:-}"
  [[ -z "$pid" ]] && return 0

  if command -v pkill >/dev/null 2>&1; then
    pkill -TERM -P "$pid" 2>/dev/null || true
  fi

  kill -TERM "$pid" 2>/dev/null || true
}

run_root() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

ensure_sudo() {
  if [[ $EUID -ne 0 ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
      die "当前不是 root，且未找到 sudo。请直接 root 运行，或安装 sudo。"
    fi

    echo "[*] 需要 sudo 权限运行 gpu_burn/lspci，请输入密码。" >&2
    sudo -v || die "sudo 验证失败"
  fi
}

ensure_tmux() {
  [[ "${USE_TMUX}" == "1" ]] || return 1

  if command -v tmux >/dev/null 2>&1; then
    return 0
  fi

  if [[ "${AUTO_INSTALL_TMUX}" != "1" ]]; then
    echo "[*] 未检测到 tmux，且 AUTO_INSTALL_TMUX=0，不自动安装。" >&2
    return 1
  fi

  echo "[*] 未检测到 tmux，将尝试自动安装 tmux..." >&2

  if [[ $EUID -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
    echo "[!] 当前不是 root，且没有 sudo，无法自动安装 tmux。" >&2
    return 1
  fi

  if command -v apt-get >/dev/null 2>&1; then
    run_root apt-get update -y || true
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y tmux
  elif command -v apt >/dev/null 2>&1; then
    run_root apt update -y || true
    run_root env DEBIAN_FRONTEND=noninteractive apt install -y tmux
  elif command -v dnf >/dev/null 2>&1; then
    run_root dnf install -y tmux
  elif command -v yum >/dev/null 2>&1; then
    run_root yum install -y tmux
  elif command -v pacman >/dev/null 2>&1; then
    run_root pacman -Sy --noconfirm tmux
  elif command -v zypper >/dev/null 2>&1; then
    run_root zypper --non-interactive install tmux
  else
    echo "[!] 未识别包管理器，无法自动安装 tmux。" >&2
    return 1
  fi

  if command -v tmux >/dev/null 2>&1; then
    echo "[*] tmux 安装成功。" >&2
    return 0
  else
    echo "[!] tmux 安装失败，将改用同窗口交替输出。" >&2
    return 1
  fi
}

prepare_lspci() {
  if ! command -v lspci >/dev/null 2>&1; then
    die "未找到 lspci，请先安装 pciutils。"
  fi

  if [[ $EUID -eq 0 ]]; then
    LSPCI=(lspci)
    return 0
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    die "当前不是 root，且未找到 sudo。请直接 root 运行，或安装 sudo。"
  fi

  if ! sudo -n true 2>/dev/null; then
    echo "[*] 需要 sudo 权限执行 lspci，请输入密码。" >&2
    sudo -v || die "sudo 验证失败"
  fi

  LSPCI=(sudo -n lspci)
}

normalize_pci_bdf() {
  local b="$1"

  if [[ "$b" =~ ^[0-9a-fA-F]{4}: ]]; then
    printf '%s' "${b#*:}"
  else
    printf '%s' "$b"
  fi
}

get_slot_override() {
  local bdf_short="$1" bdf_full="${2:-$1}"
  local entry a b a_short

  bdf_short="$(normalize_pci_bdf "$bdf_short")"

  if declare -p SLOT_OVERRIDES >/dev/null 2>&1 && [[ ${#SLOT_OVERRIDES[@]} -gt 0 ]]; then
    for entry in "${SLOT_OVERRIDES[@]}"; do
      [[ "$entry" != *"|"* ]] && continue

      a="${entry%%|*}"
      b="${entry#*|}"

      [[ -z "$b" || "$b" == "?" ]] && continue

      a_short="$(normalize_pci_bdf "$a")"

      if [[ "$a" == "$bdf_full" || "$a_short" == "$bdf_short" || "$a" == "$bdf_short" ]]; then
        printf '%s' "$b"
        return 0
      fi
    done
  fi

  return 1
}

get_pci_ancestors() {
  local bdf_short="$1" bdf_full="${2:-$1}"
  local dev_path="" parent base

  dev_path="$(readlink -f "/sys/bus/pci/devices/0000:${bdf_short}" 2>/dev/null || true)"

  if [[ -z "$dev_path" ]]; then
    dev_path="$(readlink -f "/sys/bus/pci/devices/${bdf_full}" 2>/dev/null || true)"
  fi

  if [[ -z "$dev_path" ]]; then
    dev_path="$(readlink -f "/sys/bus/pci/devices/${bdf_short}" 2>/dev/null || true)"
  fi

  [[ -z "$dev_path" ]] && return 1

  parent="$(dirname "$dev_path")"

  while [[ "$parent" != "/sys/devices" && "$parent" != "/" && "$parent" != "." ]]; do
    base="${parent##*/}"

    if [[ "$base" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]$ ]]; then
      printf '%s\n' "$base"
    fi

    parent="$(dirname "$parent")"
  done
}

sysfs_slot_by_address() {
  local target="$1"
  local target_short addr addr_short slot_dir slot

  target_short="$(normalize_pci_bdf "$target")"

  for slot_dir in /sys/bus/pci/slots/*; do
    [[ -d "$slot_dir" ]] || continue

    slot="${slot_dir##*/}"
    [[ "$slot" =~ ^[0-9]+$ ]] || continue

    addr="$(head -n1 "$slot_dir/address" 2>/dev/null || true)"
    addr="$(printf '%s' "$addr" | sed -E 's/[[:space:]]+$//')"

    [[ -z "$addr" ]] && continue

    addr_short="$(normalize_pci_bdf "$addr")"

    if [[ "$addr" == "$target" || "$addr_short" == "$target_short" ]]; then
      printf '%s' "$slot"
      return 0
    fi
  done

  return 1
}

lspci_physical_slot() {
  local bdf="$1"
  local slot=""

  if ! declare -p LSPCI >/dev/null 2>&1; then
    return 1
  fi

  slot=$("${LSPCI[@]}" -s "$bdf" -vv 2>/dev/null |
    sed -nE 's/^[[:space:]]*Physical Slot:[[:space:]]*//p' |
    head -n1 |
    sed -E 's/[[:space:]]+$//')

  if [[ -n "$slot" ]]; then
    printf '%s' "$slot"
    return 0
  fi

  return 1
}

resolve_slot() {
  local bdf_short="$1" bdf_full="${2:-$1}"
  local slot="" ancestor=""

  bdf_short="$(normalize_pci_bdf "$bdf_short")"
  [[ -z "$bdf_full" ]] && bdf_full="0000:$bdf_short"

  # 1. 手动强制映射最高优先
  if slot="$(get_slot_override "$bdf_short" "$bdf_full")"; then
    printf '%s' "$slot"
    return 0
  fi

  # 2. 尝试 /sys/bus/pci/slots，匹配设备自己
  if slot="$(sysfs_slot_by_address "0000:$bdf_short")"; then
    printf '%s' "$slot"
    return 0
  fi

  if [[ "$bdf_full" != "0000:$bdf_short" ]]; then
    if slot="$(sysfs_slot_by_address "$bdf_full")"; then
      printf '%s' "$slot"
      return 0
    fi
  fi

  # 3. 尝试 /sys/bus/pci/slots，匹配上游 bridge / root port
  while IFS= read -r ancestor; do
    [[ -z "$ancestor" ]] && continue

    if slot="$(sysfs_slot_by_address "$ancestor")"; then
      printf '%s' "$slot"
      return 0
    fi
  done < <(get_pci_ancestors "$bdf_short" "$bdf_full" || true)

  # 4. 尝试 lspci Physical Slot，设备自己
  if slot="$(lspci_physical_slot "0000:$bdf_short")"; then
    printf '%s' "$slot"
    return 0
  fi

  if [[ "$bdf_full" != "0000:$bdf_short" ]]; then
    if slot="$(lspci_physical_slot "$bdf_full")"; then
      printf '%s' "$slot"
      return 0
    fi
  fi

  if slot="$(lspci_physical_slot "$bdf_short")"; then
    printf '%s' "$slot"
    return 0
  fi

  # 5. 尝试 lspci Physical Slot，上游 bridge / root port
  while IFS= read -r ancestor; do
    [[ -z "$ancestor" ]] && continue

    if slot="$(lspci_physical_slot "$ancestor")"; then
      printf '%s' "$slot"
      return 0
    fi
  done < <(get_pci_ancestors "$bdf_short" "$bdf_full" || true)

  printf '?'
}

get_slot() {
  local bdf="$1" cfg="${2:-}"
  local bdf_short full override

  bdf_short="$(normalize_pci_bdf "$bdf")"

  if [[ "$bdf" == *:*:*.* ]]; then
    full="$bdf"
  else
    full="0000:$bdf_short"
  fi

  # 手动强制映射最高优先
  if override="$(get_slot_override "$bdf_short" "$full")"; then
    printf '%s' "$override"
    return 0
  fi

  # 如果配置里已经给了有效 SLOT，则使用配置值
  if [[ -n "$cfg" && "$cfg" != "?" ]]; then
    printf '%s' "$cfg"
    return 0
  fi

  # 否则自动解析
  resolve_slot "$bdf_short" "$full"
}

get_link_status() {
  local bdf="$1" raw="" status=""

  raw=$("${LSPCI[@]}" -s "$bdf" -vv 2>/dev/null |
    sed -nE 's/^[[:space:]]*LnkSta:[[:space:]]*//p' |
    head -n1)

  if [[ -z "$raw" ]]; then
    printf 'LnkSta: N/A'
    return 0
  fi

  # 尽量贴近你给的格式：
  #   LnkSta: Speed 2.5GT/s (downgraded), width x16
  #
  # 这里会：
  #   1. 把 Width 改成 width
  #   2. 去掉 (ok)
  #   3. 保留 (downgraded)
  status=$(printf '%s' "$raw" |
    sed -E 's/Width/width/g; s/[[:space:]]*\(ok\)//g; s/[[:space:]]+$//')

  printf 'LnkSta: %s' "$status"
}

print_devices() {
  local entry bdf cfg slot link

  [[ ${#DEVICES[@]} -eq 0 ]] && return 0

  for entry in "${DEVICES[@]}"; do
    bdf="${entry%%|*}"
    cfg="${entry#*|}"
    [[ "$cfg" == "$entry" ]] && cfg=""

    slot="$(get_slot "$bdf" "$cfg")"
    link="$(get_link_status "$bdf")"

    printf '    BDF %-12s SLOT %-5s %s\n' \
      "$bdf" "$slot" "$link"
  done
}

detect_devices() {
  local print="${1:-0}"
  local raw_lines=()

  # 优先匹配显卡设备：
  #   [0300] VGA compatible controller
  #   [0302] 3D controller
  mapfile -t raw_lines < <(
    "${LSPCI[@]}" -D -nn 2>/dev/null |
      grep -i -- "$GPU_KEYWORD" |
      grep -Ei '\[0300\]|\[0302\]|VGA compatible controller|3D controller' || true
  )

  # 如果上面没匹配到，则退回普通关键词匹配
  if [[ ${#raw_lines[@]} -eq 0 ]]; then
    mapfile -t raw_lines < <(
      "${LSPCI[@]}" -D -nn 2>/dev/null |
        grep -i -- "$GPU_KEYWORD" || true
    )
  fi

  if [[ ${#raw_lines[@]} -eq 0 ]]; then
    die "未找到包含关键词 '$GPU_KEYWORD' 的显卡设备。可设置 GPU_KEYWORD=\"\" 使用手动 DEVICES。"
  fi

  DEVICES=()

  if [[ "$print" == "1" ]]; then
    echo "[*] 根据关键词 '$GPU_KEYWORD' 找到以下显卡:"
  fi

  local line bdf_full bdf slot desc

  for line in "${raw_lines[@]}"; do
    [[ -z "$line" ]] && continue

    bdf_full="${line%% *}"
    [[ -z "$bdf_full" ]] && continue

    if [[ "$bdf_full" == 0000:* ]]; then
      bdf="${bdf_full#0000:}"
    else
      bdf="$bdf_full"
    fi

    slot="$(resolve_slot "$bdf" "$bdf_full")"
    desc="${line#* }"

    DEVICES+=("$bdf|$slot")

    if [[ "$print" == "1" ]]; then
      printf '    BDF %-12s SLOT %-5s %s\n' \
        "$bdf" "$slot" "$desc"
    fi
  done

  if [[ ${#DEVICES[@]} -eq 0 ]]; then
    die "虽然匹配到关键词 '$GPU_KEYWORD'，但没有解析出有效 BDF。"
  fi

  if [[ "$print" == "1" ]]; then
    echo "[*] 当前 PCIe 链路状态:"
    print_devices
  fi
}

setup_devices() {
  local print="${1:-0}"

  # 如果主进程已经导出了设备列表，则子进程直接使用。
  if [[ -n "${DEVICES_ENV:-}" ]]; then
    local tmp=()
    local x

    mapfile -t tmp <<< "$DEVICES_ENV"

    DEVICES=()

    if [[ ${#tmp[@]} -gt 0 ]]; then
      for x in "${tmp[@]}"; do
        [[ -n "$x" ]] && DEVICES+=("$x")
      done
    fi

    if [[ ${#DEVICES[@]} -gt 0 ]]; then
      if [[ "$print" == "1" ]]; then
        echo "[*] 使用已导出的设备列表:"
        print_devices
      fi
      return 0
    fi
  fi

  if [[ -n "${GPU_KEYWORD:-}" ]]; then
    detect_devices "$print"
  else
    if [[ "$print" == "1" ]]; then
      echo "[*] 使用手动配置 DEVICES:"
      print_devices
    fi
  fi

  if [[ ${#DEVICES[@]} -eq 0 ]]; then
    die "没有可监控的 PCIe 设备。请设置 GPU_KEYWORD 或 DEVICES。"
  fi

  DEVICES_ENV="$(printf '%s\n' "${DEVICES[@]}")"
  export DEVICES_ENV
}

nvidia_cleanup() {
  trap - INT TERM

  if [[ -n "${NVIDIA_SLEEP_PID:-}" ]]; then
    kill -TERM "$NVIDIA_SLEEP_PID" 2>/dev/null || true
  fi

  session_kill
  exit 0
}

nvidia_smi_mode() {
  trap nvidia_cleanup INT TERM

  local clear_flag="${GPU_SPEED_NVIDIA_CLEAR:-${NVIDIA_SMI_CLEAR:-1}}"
  local interval="${NVIDIA_SMI_INTERVAL:-1}"

  if ! command -v nvidia-smi >/dev/null 2>&1; then
    while true; do
      [[ "$clear_flag" == "1" ]] && printf '\033[2J\033[H'

      echo "[!] 未找到 nvidia-smi，请安装 NVIDIA 驱动。"
      echo "[*] 等待 ${interval} 秒后重试..."

      sleep "$interval" &
      NVIDIA_SLEEP_PID=$!
      wait "$NVIDIA_SLEEP_PID" || true
      NVIDIA_SLEEP_PID=""
    done
  fi

  while true; do
    [[ "$clear_flag" == "1" ]] && printf '\033[2J\033[H'

    if ! nvidia-smi ${NVIDIA_SMI_ARGS[@]+"${NVIDIA_SMI_ARGS[@]}"}; then
      echo
      echo "[!] nvidia-smi 执行失败。"
    fi

    sleep "$interval" &
    NVIDIA_SLEEP_PID=$!
    wait "$NVIDIA_SLEEP_PID" || true
    NVIDIA_SLEEP_PID=""
  done
}

monitor_cleanup() {
  trap - INT TERM

  if [[ -n "${MONITOR_SLEEP_PID:-}" ]]; then
    kill -TERM "$MONITOR_SLEEP_PID" 2>/dev/null || true
  fi

  session_kill
  exit 0
}

monitor_mode() {
  trap monitor_cleanup INT TERM

  prepare_lspci
  setup_devices "${GPU_SPEED_PRINT_INFO:-0}"

  while true; do
    local ts entry bdf cfg slot link
    ts="$(date '+%Y-%m-%d %H:%M:%S')"

    for entry in "${DEVICES[@]}"; do
      bdf="${entry%%|*}"
      cfg="${entry#*|}"
      [[ "$cfg" == "$entry" ]] && cfg=""

      slot="$(get_slot "$bdf" "$cfg")"
      link="$(get_link_status "$bdf")"

      printf '[%s] SLOT %s → BDF %s → %s\n' \
        "$ts" "$slot" "$bdf" "$link"
    done

    [[ "${SHOW_SEPARATOR}" == "1" ]] && printf -- '----\n'

    sleep "${INTERVAL}" &
    MONITOR_SLEEP_PID=$!
    wait "$MONITOR_SLEEP_PID" || true
    MONITOR_SLEEP_PID=""
  done
}

check_gpu_burn() {
  if ! [[ -d "$GPU_BURN_DIR" ]]; then
    die "找不到 gpu_burn 目录: $GPU_BURN_DIR"
  fi

  local bin_path=""

  if [[ "$GPU_BURN_BIN" == /* ]]; then
    bin_path="$GPU_BURN_BIN"
  else
    bin_path="$GPU_BURN_DIR/${GPU_BURN_BIN#./}"
  fi

  if ! [[ -e "$bin_path" ]]; then
    die "找不到 gpu_burn 可执行文件: $bin_path"
  fi

  if ! [[ -x "$bin_path" ]]; then
    echo "[*] 尝试给 $bin_path 添加可执行权限。" >&2
    chmod +x "$bin_path" 2>/dev/null || true
  fi
}

gpu_cleanup() {
  trap - INT TERM

  kill_tree "$GPU_CHILD"
  session_kill

  exit 0
}

gpu_mode() {
  check_gpu_burn
  ensure_sudo

  trap gpu_cleanup INT TERM

  (
    cd "$GPU_BURN_DIR" || exit 1

    if [[ $EUID -ne 0 ]]; then
      exec sudo "$GPU_BURN_BIN" "${GPU_BURN_ARGS[@]}"
    else
      exec "$GPU_BURN_BIN" "${GPU_BURN_ARGS[@]}"
    fi
  ) &

  GPU_CHILD=$!

  wait "$GPU_CHILD" || true

  gpu_cleanup
}

tmux_leftmost_pane() {
  local socket="$1"
  local session="$2"

  tmux -L "$socket" list-panes -t "$session" \
    -F '#{pane_left} #{window_index}.#{pane_index}' 2>/dev/null |
    sort -n |
    head -n1 |
    awk '{print $2}'
}

tmux_rightmost_pane() {
  local socket="$1"
  local session="$2"

  tmux -L "$socket" list-panes -t "$session" \
    -F '#{pane_left} #{window_index}.#{pane_index}' 2>/dev/null |
    sort -nr |
    head -n1 |
    awk '{print $2}'
}

start_tmux() {
  local session="gpu-speed"
  local socket="gpu-speed-$$"
  local cols lines self_q env_prefix
  local nvidia_cmd gpu_cmd mon_cmd
  local left_pane right_pane

  cols="$(tput cols 2>/dev/null || true)"
  lines="$(tput lines 2>/dev/null || true)"

  cols="${cols:-80}"
  lines="${lines:-24}"

  self_q="$(printf '%q' "$SELF")"

  env_prefix="GPU_SPEED_TMUX_SOCKET=$socket GPU_SPEED_PRINT_INFO=0 GPU_SPEED_NVIDIA_CLEAR=${NVIDIA_SMI_CLEAR}"

  nvidia_cmd="$env_prefix bash $self_q __nvidia"
  gpu_cmd="$env_prefix bash $self_q __gpu"
  mon_cmd="$env_prefix bash $self_q __monitor"

  echo "[*] 使用独立 tmux socket: $socket" >&2
  echo "[*] 布局：左上 nvidia-smi，左下 gpu_burn，右侧 LnkSta 监控。" >&2
  echo "[*] 已绑定 Ctrl+C -> 退出整个 gpu-speed tmux 会话。" >&2

  # 1. 先启动左侧 nvidia-smi。
  if ! tmux -L "$socket" new-session -d -s "$session" -x "$cols" -y "$lines" "$nvidia_cmd"; then
    echo "[*] tmux 启动失败，改用同窗口交替输出。" >&2
    start_plain
    return
  fi

  # 2. 向右水平分出 LnkSta 监控。
  #    此时布局：左 nvidia-smi，右 LnkSta 监控。
  if ! tmux -L "$socket" split-window -h -p 50 -t "$session" "$mon_cmd" 2>/dev/null; then
    if ! tmux -L "$socket" split-window -h -l $(( cols / 2 )) -t "$session" "$mon_cmd"; then
      tmux -L "$socket" kill-server 2>/dev/null || true
      echo "[*] tmux 分屏失败，改用同窗口交替输出。" >&2
      start_plain
      return
    fi
  fi

  # 找到左侧 pane。
  left_pane="$(tmux_leftmost_pane "$socket" "$session")"

  if [[ -z "$left_pane" ]]; then
    left_pane="$(tmux -L "$socket" list-panes -t "$session" -F '#{window_index}.#{pane_index}' 2>/dev/null | head -n1)"
  fi

  if [[ -z "$left_pane" ]]; then
    left_pane="{left}"
  fi

  # 3. 把左侧 nvidia-smi 垂直分成上下两块。
  #    上方继续 nvidia-smi。
  #    下方启动 gpu_burn。
  if ! tmux -L "$socket" split-window -v -p 50 -t "$session:$left_pane" "$gpu_cmd" 2>/dev/null; then
    if ! tmux -L "$socket" split-window -v -l $(( lines / 2 )) -t "$session:$left_pane" "$gpu_cmd"; then
      tmux -L "$socket" kill-server 2>/dev/null || true
      echo "[*] tmux 分屏失败，改用同窗口交替输出。" >&2
      start_plain
      return
    fi
  fi

  # 4. 可选：调整右侧监控窗口宽度。
  right_pane="$(tmux_rightmost_pane "$socket" "$session")"

  if [[ -z "$right_pane" ]]; then
    right_pane="{right}"
  fi

  if [[ -n "${TMUX_RIGHT_PANE_WIDTH:-}" ]]; then
    tmux -L "$socket" resize-pane -t "$session:$right_pane" -x "$TMUX_RIGHT_PANE_WIDTH" 2>/dev/null ||
      tmux -L "$socket" resize-pane -t "$session:$right_pane" -x $(( cols / 2 )) 2>/dev/null ||
      true
  fi

  # 关键：在这个独立 tmux server 内，Ctrl+C 直接杀掉整个 tmux server。
  # 因为这会影响 copy-mode，所以 copy-mode / copy-mode-vi 也一并绑定。
  tmux -L "$socket" bind-key -n C-c kill-server 2>/dev/null || true
  tmux -L "$socket" bind-key -T copy-mode C-c kill-server 2>/dev/null || true
  tmux -L "$socket" bind-key -T copy-mode-vi C-c kill-server 2>/dev/null || true

  trap "tmux -L '$socket' kill-server 2>/dev/null || true" EXIT
  trap 'exit 0' INT TERM

  tmux -L "$socket" attach -t "$session"
}

cleanup_plain() {
  trap - INT TERM EXIT

  kill_tree "$NVIDIA_PID"
  kill_tree "$GPU_PID"
  kill_tree "$MON_PID"

  wait 2>/dev/null || true

  exit 0
}

start_plain() {
  echo "[*] 当前使用同窗口交替输出模式。按一次 Ctrl+C 会退出全部。" >&2
  echo "[*] 注意：同窗口模式下 nvidia-smi、gpu_burn、LnkSta 三路输出会交错。" >&2

  trap cleanup_plain INT TERM EXIT

  GPU_SPEED_TMUX_SOCKET="" GPU_SPEED_PRINT_INFO=0 GPU_SPEED_NVIDIA_CLEAR=0 \
    bash "$SELF" __nvidia &
  NVIDIA_PID=$!

  GPU_SPEED_TMUX_SOCKET="" GPU_SPEED_PRINT_INFO=0 \
    bash "$SELF" __gpu &
  GPU_PID=$!

  GPU_SPEED_TMUX_SOCKET="" GPU_SPEED_PRINT_INFO=0 \
    bash "$SELF" __monitor &
  MON_PID=$!

  wait "$NVIDIA_PID" "$GPU_PID" "$MON_PID" || true

  cleanup_plain
}

main() {
  case "${1:-}" in
    __nvidia)
      nvidia_smi_mode
      exit 0
      ;;
    __monitor)
      monitor_mode
      exit 0
      ;;
    __gpu)
      gpu_mode
      exit 0
      ;;
  esac

  check_gpu_burn
  ensure_sudo
  prepare_lspci
  setup_devices 1

  if [[ "${USE_TMUX}" == "1" ]] && ensure_tmux && [[ -t 1 ]]; then
    start_tmux
  else
    if [[ "${USE_TMUX}" != "1" ]]; then
      echo "[*] USE_TMUX=0，不使用 tmux。" >&2
    elif ! [[ -t 1 ]]; then
      echo "[*] 当前不是交互式终端，无法 attach tmux，改用同窗口交替输出。" >&2
    fi

    start_plain
  fi
}

main "$@"