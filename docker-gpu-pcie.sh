#!/usr/bin/env bash
set -euo pipefail

# ========================= 配置区 =========================

# 原脚本工作目录
WORK_DIR="${WORK_DIR:-$HOME/vllm-deploy}"

# 是否使用 tmux 分屏
USE_TMUX="${USE_TMUX:-1}"

# 如果没有 tmux，是否自动安装
AUTO_INSTALL_TMUX="${AUTO_INSTALL_TMUX:-1}"

# 中间 nvitop 窗口高度百分比
NVITOP_PANE_PERCENT="${NVITOP_PANE_PERCENT:-10}"
# 如果设置了 NVITOP_PANE_LINES > 0，则优先使用固定行数
NVITOP_PANE_LINES="${NVITOP_PANE_LINES:-25}"

# 底部 PCIe 窗口行数（固定）
PCIE_PANE_LINES="${PCIE_PANE_LINES:-3}"

# PCIe 监控刷新间隔（秒）
PCIE_INTERVAL="${PCIE_INTERVAL:-1}"

# Ctrl+C 是否同时退出所有窗口
CTRL_C_KILL_ALL="${CTRL_C_KILL_ALL:-1}"

# docker down / logs 结束后，是否保持窗口打开
KEEP_OPEN_AFTER_DONE="${KEEP_OPEN_AFTER_DONE:-1}"

# 如果没有 nvitop，是否回退到 nvidia-smi -l 1
NVIDIA_SMI_FALLBACK="${NVIDIA_SMI_FALLBACK:-1}"

# nvitop 命令
NVITOP_CMD=(nvitop)

# nvidia-smi fallback 命令
NVIDIA_SMI_FALLBACK_CMD=(nvidia-smi -l 1)

# GPU 关键词，用于 lspci 过滤
GPU_KEYWORD="${GPU_KEYWORD:-3090}"

# 手动 BDF -> SLOT 强制映射
SLOT_OVERRIDES=()
# SLOT_OVERRIDES=(
#   "03:00.0|6"
#   "84:00.0|7"
# )

# =========================================================

SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"

keep_open() {
  if [[ "${KEEP_OPEN_AFTER_DONE:-1}" == "1" ]]; then
    echo
    echo "[*] 窗口保持打开，按 Ctrl+C 退出。"
    while :; do
      sleep 3600
    done
  fi
}

# ========================= Docker (top pane) =========================

top_mode() {
  set +e

  local action="${DOCKER_ACTION:-}"
  local compose_file="${DOCKER_COMPOSE_FILE:-docker-compose.yml}"
  local work_dir="${WORK_DIR:-$HOME/vllm-deploy}"

  echo "[*] 工作目录: ${work_dir}"

  cd "$work_dir" || {
    echo "[!] 无法进入目录: ${work_dir}"
    keep_open
    return 1
  }

  if ! command -v docker >/dev/null 2>&1; then
    echo "[!] 未找到 docker 命令。"
    keep_open
    return 1
  fi

  case "$action" in
    up)
      echo "[*] docker compose -f ${compose_file} up -d"
      docker compose -f "$compose_file" up -d
      local rc=$?

      if [[ $rc -ne 0 ]]; then
        echo
        echo "[!] docker compose up -d 失败，返回码: ${rc}"
        keep_open
        return "$rc"
      fi

      echo
      echo "[*] docker compose -f ${compose_file} logs -f"
      docker compose -f "$compose_file" logs -f
      rc=$?

      echo
      echo "[*] docker compose logs 已退出，返回码: ${rc}"
      keep_open
      return "$rc"
      ;;

    down)
      echo "[*] docker compose -f ${compose_file} down"
      docker compose -f "$compose_file" down
      local rc=$?

      echo
      if [[ $rc -eq 0 ]]; then
        echo "[*] docker compose down 完成。"
      else
        echo "[!] docker compose down 失败，返回码: ${rc}"
      fi

      keep_open
      return "$rc"
      ;;

    *)
      echo "[!] 内部错误：未知 DOCKER_ACTION='${action}'"
      keep_open
      return 1
      ;;
  esac
}

# ========================= nvitop (middle pane) =========================

middle_mode() {
  if [[ ${#NVITOP_CMD[@]} -gt 0 ]] && command -v "${NVITOP_CMD[0]}" >/dev/null 2>&1; then
    exec "${NVITOP_CMD[@]}"
  fi

  echo "[!] 未找到 nvitop。"
  echo "    安装：pip install nvitop"
  echo

  if [[ "${NVIDIA_SMI_FALLBACK:-1}" == "1" ]] &&
     [[ ${#NVIDIA_SMI_FALLBACK_CMD[@]} -gt 0 ]] &&
     command -v "${NVIDIA_SMI_FALLBACK_CMD[0]}" >/dev/null 2>&1; then
    echo "[*] fallback: ${NVIDIA_SMI_FALLBACK_CMD[*]}"
    sleep 2
    exec "${NVIDIA_SMI_FALLBACK_CMD[@]}"
  fi

  echo "[!] nvitop 不可用，且未启用 nvidia-smi fallback。"
  while :; do
    sleep 3600
  done
}

# ========================= PCIe (bottom pane) =========================

# lspci 命令（需要 sudo）
if [[ $EUID -eq 0 ]]; then
  LSPCI=(lspci)
else
  if command -v sudo >/dev/null 2>&1; then
    sudo -v 2>/dev/null || true
    LSPCI=(sudo -n lspci)
  else
    LSPCI=(lspci)
  fi
fi

normalize_pci_bdf() {
  local b="$1"
  if [[ "$b" =~ ^[0-9a-fA-F]{4}: ]]; then
    printf '%s' "${b#*:}"
  else
    printf '%s' "$b"
  fi
}

get_slot_override() {
  local bdf_short="$1"
  local bdf_full="${2:-$1}"
  local entry a b a_short

  if [[ ${#SLOT_OVERRIDES[@]} -gt 0 ]]; then
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
  local bdf_short="$1"
  local bdf_full="${2:-$1}"
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
  local bdf_short="$1"
  local bdf_full="${2:-$1}"
  local slot="" ancestor=""

  bdf_short="$(normalize_pci_bdf "$bdf_short")"
  [[ -z "$bdf_full" ]] && bdf_full="0000:$bdf_short"

  if slot="$(get_slot_override "$bdf_short" "$bdf_full")"; then
    printf '%s' "$slot"; return 0
  fi
  if slot="$(sysfs_slot_by_address "0000:$bdf_short")"; then
    printf '%s' "$slot"; return 0
  fi
  if [[ "$bdf_full" != "0000:$bdf_short" ]]; then
    if slot="$(sysfs_slot_by_address "$bdf_full")"; then
      printf '%s' "$slot"; return 0
    fi
  fi
  while IFS= read -r ancestor; do
    [[ -z "$ancestor" ]] && continue
    if slot="$(sysfs_slot_by_address "$ancestor")"; then
      printf '%s' "$slot"; return 0
    fi
  done < <(get_pci_ancestors "$bdf_short" "$bdf_full" || true)
  if slot="$(lspci_physical_slot "0000:$bdf_short")"; then
    printf '%s' "$slot"; return 0
  fi
  if [[ "$bdf_full" != "0000:$bdf_short" ]]; then
    if slot="$(lspci_physical_slot "$bdf_full")"; then
      printf '%s' "$slot"; return 0
    fi
  fi
  if slot="$(lspci_physical_slot "$bdf_short")"; then
    printf '%s' "$slot"; return 0
  fi
  while IFS= read -r ancestor; do
    [[ -z "$ancestor" ]] && continue
    if slot="$(lspci_physical_slot "$ancestor")"; then
      printf '%s' "$slot"; return 0
    fi
  done < <(get_pci_ancestors "$bdf_short" "$bdf_full" || true)
  printf '?'
}

get_link_status() {
  local bdf_full="$1"
  local raw="" status=""

  raw=$("${LSPCI[@]}" -s "$bdf_full" -vv 2>/dev/null |
    sed -nE 's/^[[:space:]]*LnkSta:[[:space:]]*//p' |
    head -n1)

  if [[ -z "$raw" ]]; then
    printf 'N/A'
    return 0
  fi

  status=$(printf '%s' "$raw" |
    sed -E 's/Width/width/g; s/[[:space:]]*\[ok\]//g; s/[[:space:]]+$//')

  printf '%s' "$status"
}

sort_devices_by_slot() {
  local n=${#DEV_SLOT[@]}
  [[ $n -le 1 ]] && return
  local sorted_indices
  sorted_indices=$(
    for i in "${!DEV_SLOT[@]}"; do
      printf '%d %s\n' "$i" "${DEV_SLOT[i]}"
    done | sort -t' ' -k2,2n -k1,1n | awk '{print $1}'
  )
  local new_short=() new_slot=() new_full=()
  for i in $sorted_indices; do
    new_short+=("${DEV_SHORT[i]}")
    new_slot+=("${DEV_SLOT[i]}")
    new_full+=("${DEV_FULL[i]}")
  done
  DEV_SHORT=("${new_short[@]}")
  DEV_SLOT=("${new_slot[@]}")
  DEV_FULL=("${new_full[@]}")
}

detect_devices() {
  local raw_lines=()
  local line bdf_full bdf_short slot

  if [[ -z "$GPU_KEYWORD" ]]; then
    return 1
  fi

  mapfile -t raw_lines < <(
    "${LSPCI[@]}" -D -nn 2>/dev/null |
      grep -i -- "$GPU_KEYWORD" |
      grep -Ei '\[0300\]|\[0302\]|VGA compatible controller|3D controller' || true
  )

  if [[ ${#raw_lines[@]} -eq 0 ]]; then
    mapfile -t raw_lines < <(
      "${LSPCI[@]}" -D -nn 2>/dev/null |
        grep -i -- "$GPU_KEYWORD" || true
    )
  fi

  if [[ ${#raw_lines[@]} -eq 0 ]]; then
    return 1
  fi

  DEV_SHORT=()
  DEV_SLOT=()
  DEV_FULL=()

  for line in "${raw_lines[@]}"; do
    [[ -z "$line" ]] && continue
    bdf_full="${line%% *}"
    [[ -z "$bdf_full" ]] && continue
    bdf_short="$(normalize_pci_bdf "$bdf_full")"
    slot="$(resolve_slot "$bdf_short" "$bdf_full")"
    DEV_SHORT+=("$bdf_short")
    DEV_SLOT+=("$slot")
    DEV_FULL+=("$bdf_full")
  done

  [[ ${#DEV_FULL[@]} -eq 0 ]] && return 1
  sort_devices_by_slot
  return 0
}

bottom_mode() {
  # PCIe link status monitor — clear screen, show only latest lines
  # Fix PATH for non-interactive tmux pane shells
  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH+:$PATH}"

  if ! command -v lspci >/dev/null 2>&1; then
    echo "[!] 未找到 lspci，请先安装 pciutils。"
    while :; do sleep 3600; done
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    echo "[!] 未找到 sudo，PCIe 信息可能无法读取。" >&2
  fi

  # Re-init LSPCI for this subshell (tmux pane has its own bash)
  if [[ $EUID -eq 0 ]]; then
    LSPCI=(lspci)
  elif command -v sudo >/dev/null 2>&1; then
    sudo -v 2>/dev/null || true
    LSPCI=(sudo -n lspci)
  else
    LSPCI=(lspci)
  fi

  if ! detect_devices; then
    echo "[!] 未找到包含关键词 '$GPU_KEYWORD' 的 PCIe 设备。"
    while :; do sleep 3600; done
  fi

  trap 'exit 0' INT TERM

  while true; do
    # Clear screen
    printf '\033[2J\033[H'

    for i in "${!DEV_FULL[@]}"; do
      link="$(get_link_status "${DEV_FULL[i]}")"
      printf 'SLOT %-3s → BDF %-12s → %s\n' \
        "${DEV_SLOT[i]}" \
        "${DEV_SHORT[i]}" \
        "$link"
    done

    sleep "$PCIE_INTERVAL"
  done
}

# ========================= tmux helpers =========================

run_root() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
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
    echo "[!] tmux 安装失败，将退回原始模式。" >&2
    return 1
  fi
}

tmux_topmost_pane() {
  local socket="$1"
  local session="$2"
  {
    tmux -L "$socket" list-panes -t "$session" \
      -F '#{pane_top} #{window_index}.#{pane_index}' 2>/dev/null || true
  } | sort -n 2>/dev/null | awk 'NR == 1 { print $2; exit }' || true
}

tmux_bottommost_pane() {
  local socket="$1"
  local session="$2"
  {
    tmux -L "$socket" list-panes -t "$session" \
      -F '#{pane_top} #{window_index}.#{pane_index}' 2>/dev/null || true
  } | sort -nr 2>/dev/null | awk 'NR == 1 { print $2; exit }' || true
}

run_original() {
  cd "$WORK_DIR"
  case "${ACTION}" in
    up)
      docker compose -f "${COMPOSE_FILE}" up -d
      docker compose -f "${COMPOSE_FILE}" logs -f
      ;;
    down)
      docker compose -f "${COMPOSE_FILE}" down
      ;;
  esac
}

# ========================= 三屏启动 =========================
#
# 策略：split-window 直接传命令作为 pane 的初始进程（不依赖 send-keys）
#
#   Pane 0 (top):    docker logs     — new-session 创建，跑 top_cmd
#   Pane 1 (middle): nvitop          — 先 split pane 0 底部，固定 middle_lines
#   Pane 2 (bottom): pcie monitor    — 再 split pane 0 底部，固定 pcie_lines
#
# tmux split-window -v -l 第二次 split 时新 pane 出现在窗口最底部，
# 所以必须先 split nvitop（让它停在中间），再 split PCIe（它出现在最底部）。
#
# 最终布局：
#   [ pane 0: top_cmd    ]  ← 剩余空间
#   [ pane 1: middle_cmd ]  ← middle_lines 行
#   [ pane 2: bottom_cmd ]  ← pcie_lines 行

start_tmux() {
  set +e

  local session="dgpc-$$"
  local socket="dgpc-$$"
  local self_q action_q compose_q workdir_q keep_q
  local top_cmd middle_cmd bottom_cmd
  local term_cols term_lines
  local middle_lines pcie_lines
  local lines_val middle_percent

  term_cols="$(tput cols 2>/dev/null || echo 80)"
  term_lines="$(tput lines 2>/dev/null || echo 24)"
  [[ "$term_cols" =~ ^[0-9]+$ ]] || term_cols=80
  [[ "$term_lines" =~ ^[0-9]+$ ]] || term_lines=24

  self_q="$(printf '%q' "$SELF")"
  action_q="$(printf '%q' "$ACTION")"
  compose_q="$(printf '%q' "$COMPOSE_FILE")"
  workdir_q="$(printf '%q' "$WORK_DIR")"
  keep_q="$(printf '%q' "$KEEP_OPEN_AFTER_DONE")"

  top_cmd="WORK_DIR=$workdir_q DOCKER_ACTION=$action_q DOCKER_COMPOSE_FILE=$compose_q KEEP_OPEN_AFTER_DONE=$keep_q bash $self_q __top"
  middle_cmd="bash $self_q __middle"
  bottom_cmd="GPU_KEYWORD=$GPU_KEYWORD bash $self_q __bottom"

  echo "[*] 三屏分屏：上方 docker，中间 nvitop，底部 PCIe。session=${session}" >&2
  echo "[debug] 终端尺寸: ${term_cols}x${term_lines}" >&2

  # --- 1) 创建 session，pane 0 跑 top_cmd ---
  if ! tmux -L "$socket" new-session -d -s "$session" -x "$term_cols" -y "$term_lines" "$top_cmd"; then
    echo "[debug] new-session -x/-y 失败，尝试普通 new-session。" >&2
    if ! tmux -L "$socket" new-session -d -s "$session" "$top_cmd"; then
      echo "[!] tmux 启动失败，退回原始模式。" >&2
      set -e
      run_original
      return
    fi
    tmux -L "$socket" resize-window -t "$session" -x "$term_cols" -y "$term_lines" 2>/dev/null || true
    term_lines="$(tmux -L "$socket" display-message -p -t "$session" '#{window_height}' 2>/dev/null || echo 24)"
    [[ "$term_lines" =~ ^[0-9]+$ ]] || term_lines=24
  fi

  # --- 计算 pane 高度 ---
  pcie_lines="$PCIE_PANE_LINES"
  [[ "$pcie_lines" =~ ^[0-9]+$ ]] || pcie_lines=4
  (( pcie_lines < 2 )) && pcie_lines=2

  middle_percent="${NVITOP_PANE_PERCENT}"
  lines_val="${NVITOP_PANE_LINES:-0}"
  if ! [[ "$middle_percent" =~ ^[0-9]+$ ]]; then middle_percent=20; fi
  (( middle_percent < 5 ))   && middle_percent=5
  (( middle_percent > 95 ))  && middle_percent=95

  local max_middle=$(( term_lines - pcie_lines - 2 ))
  (( max_middle < 1 )) && max_middle=1

  if [[ "$lines_val" =~ ^[0-9]+$ ]] && (( lines_val > 0 )); then
    middle_lines="$lines_val"
    echo "[*] nvitop: 固定 ${middle_lines} 行; PCIe: 固定 ${pcie_lines} 行" >&2
  else
    middle_lines=$(( (term_lines - pcie_lines) * middle_percent / 100 ))
    (( middle_lines < 1 )) && middle_lines=1
    echo "[*] nvitop: ${middle_percent}% → ${middle_lines} 行; PCIe: 固定 ${pcie_lines} 行" >&2
  fi
  (( middle_lines > max_middle )) && middle_lines="$max_middle"

  echo "[debug] 布局: docker(剩余) + nvitop(${middle_lines}行) + PCIe(${pcie_lines}行)" >&2

  # --- 2) 先 split pane 0 底部 → pane 1 (nvitop, middle_lines) ---
  # tmux 第二次 split 新 pane 会出现在窗口最底部，所以 nvitop 必须第一个 split，
  # 这样后面的 PCIe split 会把它顶上到中间。
  if ! tmux -L "$socket" split-window -v -l "$middle_lines" -t "$session:0" "$middle_cmd"; then
    echo "[!] 分屏 1 (nvitop) 失败，尝试 fallback 两屏模式（docker + nvitop）。" >&2
    if ! tmux -L "$socket" split-window -v -l "$(( term_lines - 2 ))" -t "$session:0" "$middle_cmd"; then
      echo "[!] fallback 也失败，退回原始模式。" >&2
      tmux -L "$socket" kill-server 2>/dev/null || true
      set -e
      run_original
      return
    fi
  fi

  # --- 3) 再 split pane 0 底部 → pane 2 (pcie, pcie_lines) ---
  # 这个新 pane 会出现在窗口最底部，正好是 PCIe 的位置
  if ! tmux -L "$socket" split-window -v -l "$pcie_lines" -t "$session:0" "$bottom_cmd"; then
    echo "[!] 分屏 2 (PCIe) 失败，回退为两屏模式（docker + nvitop）。" >&2
  fi

  # --- 最终尺寸 ---
  tmux -L "$socket" list-panes -t "$session" \
    -F '[debug] pane#{pane_index} h=#{pane_height} top=#{pane_top} cmd=#{pane_current_command}' >&2 || true

  # --- 焦点切回上方 ---
  tmux -L "$socket" select-pane -t "$session:0" 2>/dev/null || true

  # --- Ctrl+C 退出全部 ---
  if [[ "${CTRL_C_KILL_ALL}" == "1" ]]; then
    tmux -L "$socket" bind-key -n C-c kill-server 2>/dev/null || true
    tmux -L "$socket" bind-key -T copy-mode C-c kill-server 2>/dev/null || true
    tmux -L "$socket" bind-key -T copy-mode-vi C-c kill-server 2>/dev/null || true
  fi

  trap "tmux -L '$socket' kill-server 2>/dev/null || true" EXIT
  trap 'exit 0' INT TERM

  tmux -L "$socket" attach -t "$session"
}

# ========================= 内部模式 =========================

case "${1:-}" in
  __top)
    top_mode
    exit $?
    ;;
  __middle)
    middle_mode
    exit $?
    ;;
  __bottom)
    bottom_mode
    exit $?
    ;;
esac

# ========================= 原始参数逻辑 =========================

ACTION=""
ENV_TAG=""
COMPOSE_FILE="docker-compose.yml"

if [[ $# -eq 1 ]]; then
  ACTION="$1"
elif [[ $# -eq 2 ]]; then
  ACTION="$1"
  ENV_TAG="$2"
  COMPOSE_FILE="docker-compose-${ENV_TAG}.yml"
else
  echo "参数错误！"
  echo "用法1：$0 up|down                # 使用默认 docker-compose.yml"
  echo "用法2：$0 up|down CN|tune        # 使用 docker-compose-CN.yml / docker-compose-tune.yml"
  echo
  echo "附加说明："
  echo "  三屏分屏：上方 docker 日志，中间 nvitop，底部 PCIe 链路状态。"
  echo "  禁用分屏：USE_TMUX=0 $0 up"
  echo "  调整 nvitop 行数：NVITOP_PANE_LINES=20 $0 up"
  echo "  调整 PCIe 行数：PCIE_PANE_LINES=4 $0 up"
  exit 1
fi

case "${ACTION}" in
  up|down)
    ;;
  *)
    echo "错误：第一个参数仅支持 up / down"
    echo "用法1：$0 up|down"
    echo "用法2：$0 up|down CN|tune"
    exit 1
    ;;
esac

if [[ ! -d "$WORK_DIR" ]]; then
  echo "错误：工作目录不存在 -> ${WORK_DIR}"
  exit 1
fi

if [[ ! -f "${WORK_DIR}/${COMPOSE_FILE}" && ! -f "${COMPOSE_FILE}" ]]; then
  echo "错误：配置文件不存在 -> ${WORK_DIR}/${COMPOSE_FILE}"
  exit 1
fi

# ========================= 启动 =========================

if [[ "${USE_TMUX}" == "1" ]] && ensure_tmux && [[ -t 1 ]]; then
  start_tmux
else
  if [[ "${USE_TMUX}" != "1" ]]; then
    echo "[*] USE_TMUX=0，使用原始模式。" >&2
  elif ! [[ -t 1 ]]; then
    echo "[*] 当前不是交互式终端，使用原始模式。" >&2
  fi

  run_original
fi