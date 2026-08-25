#!/usr/bin/env bash
set -euo pipefail

SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
WORK_DIR="${WORK_DIR:-$HOME/vllm-deploy}"
GPU_KEYWORD="${GPU_KEYWORD:-3090}"

MID_LINES="${MID_LINES:-21}"
GPU_LINES="${GPU_LINES:-3}"

keep_open() {
    echo
    echo "[*] 窗口保持打开，按 Ctrl+C 退出。"
    while :; do
        sleep 3600
    done
}

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

mid_mode() {
    set +e

    if command -v nvitop >/dev/null 2>&1; then
        exec nvitop
    fi

    echo "[!] 未找到 nvitop。"
    echo "    可以安装："
    echo "      pip install nvitop"
    echo "    或："
    echo "      python3 -m pip install nvitop"
    echo

    if command -v watch >/dev/null 2>&1 && command -v nvidia-smi >/dev/null 2>&1; then
        echo "[*] 使用 fallback: watch -n 1 -t nvidia-smi"
        sleep 2
        exec watch -n 1 -t nvidia-smi
    fi

    if command -v nvidia-smi >/dev/null 2>&1; then
        echo "[*] 使用 fallback: nvidia-smi -l 1"
        sleep 2
        exec nvidia-smi -l 1
    fi

    echo "[!] nvitop 和 nvidia-smi 都不可用。"
    while :; do
        sleep 3600
    done
}

normalize_pci_bdf() {
    local b="$1"

    if [[ "$b" =~ ^[0-9a-fA-F]{4}: ]]; then
        printf '%s' "${b#*:}"
    else
        printf '%s' "$b"
    fi
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

    while IFS= read -r ancestor; do
        [[ -z "$ancestor" ]] && continue

        if slot="$(sysfs_slot_by_address "$ancestor")"; then
            printf '%s' "$slot"
            return 0
        fi
    done < <(get_pci_ancestors "$bdf_short" "$bdf_full" || true)

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

    while IFS= read -r ancestor; do
        [[ -z "$ancestor" ]] && continue

        if slot="$(lspci_physical_slot "$ancestor")"; then
            printf '%s' "$slot"
            return 0
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
        printf 'LnkSta: N/A'
        return 0
    fi

    status=$(printf '%s' "$raw" |
        sed -E 's/Width/width/g; s/[[:space:]]*\(ok\)//g; s/[[:space:]]+$//')

    printf 'LnkSta: %s' "$status"
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

detect_gpu_devices_silent() {
    local raw_lines=()
    local line bdf_full bdf_short slot

    DEV_SHORT=()
    DEV_SLOT=()
    DEV_FULL=()

    if [[ -z "${GPU_KEYWORD:-}" ]]; then
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

    for line in "${raw_lines[@]}"; do
        [[ -z "$line" ]] && continue

        bdf_full="${line%% *}"
        [[ -z "$bdf_full" ]] && continue

        bdf_short="$(normalize_pci_bdf "$bdf_full")"
        slot="$(resolve_slot "$bdf_short" "$bdf_full")"

        DEV_SHORT+=("$bdf_short")
        DEV_SLOT+=("$slot")
        DEV_FULL+=("$bdf_full")

        if (( ${#DEV_FULL[@]} >= 2 )); then
            break
        fi
    done

    sort_devices_by_slot

    [[ ${#DEV_FULL[@]} -gt 0 ]]
}

gpu_mode() {
    set +e

    local interval=1
    local count i link
    local has_tput=0

    if ! command -v lspci >/dev/null 2>&1; then
        while true; do
            printf '\033[H\033[2J'
            printf 'SLOT ? | BDF ? | LnkSta: lspci missing\n'
            printf 'SLOT ? | BDF ? | LnkSta: N/A\n'
            sleep 1
        done
    fi

    if [[ $EUID -eq 0 ]]; then
        LSPCI=(lspci)
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        LSPCI=(sudo -n lspci)
    else
        LSPCI=(lspci)
    fi

    detect_gpu_devices_silent || true

    if command -v tput >/dev/null 2>&1 && tput cup 0 0 >/dev/null 2>&1; then
        has_tput=1
        tput civis >/dev/null 2>&1 || true
        trap 'tput cnorm >/dev/null 2>&1 || true; exit 0' INT TERM EXIT
    else
        trap 'exit 0' INT TERM
    fi

    while true; do
        if (( has_tput )); then
            tput cup 0 0
            tput ed
        else
            printf '\033[H\033[2J'
        fi

        count=${#DEV_FULL[@]}

        for i in 0 1; do
            if (( i < count )); then
                link="$(get_link_status "${DEV_FULL[i]}")"
                printf 'SLOT %s | BDF %s | %s\n' \
                    "${DEV_SLOT[i]}" \
                    "${DEV_SHORT[i]}" \
                    "$link"
            else
                printf 'SLOT ? | BDF ? | LnkSta: N/A\n'
            fi
        done

        sleep "$interval"
    done
}

run_root() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

ensure_tmux() {
    if command -v tmux >/dev/null 2>&1; then
        return 0
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
        echo "[!] tmux 安装失败。" >&2
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

tmux_middle_pane() {
    local socket="$1"
    local session="$2"

    {
        tmux -L "$socket" list-panes -t "$session" \
            -F '#{pane_top} #{window_index}.#{pane_index}' 2>/dev/null || true
    } | sort -n 2>/dev/null | awk 'NR == 2 { print $2; exit }' || true
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

start_tmux() {
    set +e

    local session="docker-gpu-$$"
    local socket="docker-gpu-$$"

    local self_q action_q compose_q workdir_q gpu_keyword_q
    local top_cmd mid_cmd gpu_cmd

    local term_cols term_lines
    local mid_lines=${MID_LINES}
    local gpu_lines=${GPU_LINES}
    local total_bottom max_bottom

    local top_pane middle_pane bottom_pane

    term_cols="$(tput cols 2>/dev/null || echo 80)"
    term_lines="$(tput lines 2>/dev/null || echo 24)"

    [[ "$term_cols" =~ ^[0-9]+$ ]] || term_cols=80
    [[ "$term_lines" =~ ^[0-9]+$ ]] || term_lines=24

    self_q="$(printf '%q' "$SELF")"
    action_q="$(printf '%q' "$ACTION")"
    compose_q="$(printf '%q' "$COMPOSE_FILE")"
    workdir_q="$(printf '%q' "$WORK_DIR")"
    gpu_keyword_q="$(printf '%q' "$GPU_KEYWORD")"

    top_cmd="WORK_DIR=$workdir_q DOCKER_ACTION=$action_q DOCKER_COMPOSE_FILE=$compose_q bash $self_q __top"
    mid_cmd="bash $self_q __mid"
    gpu_cmd="GPU_KEYWORD=$gpu_keyword_q bash $self_q __gpu"

    echo "[*] 使用 tmux 三屏：上方 docker，中间 nvitop/nvidia-smi，下方 GPU PCIe。session=${session}" >&2

    if ! tmux -L "$socket" new-session -d -s "$session" -x "$term_cols" -y "$term_lines" "$top_cmd"; then
        if ! tmux -L "$socket" new-session -d -s "$session" "$top_cmd"; then
            echo "[!] tmux 启动失败，退回原始 docker 模式。" >&2
            set -e
            run_original
            return
        fi

        tmux -L "$socket" resize-window -t "$session" -x "$term_cols" -y "$term_lines" 2>/dev/null || true

        term_lines="$(tmux -L "$socket" display-message -p -t "$session" '#{window_height}' 2>/dev/null || echo 24)"
        [[ "$term_lines" =~ ^[0-9]+$ ]] || term_lines=24
    fi

    max_bottom=$((term_lines - 4))
    if (( max_bottom < 6 )); then
        max_bottom=6
    fi

    total_bottom=$((mid_lines + gpu_lines + 1))

    if (( total_bottom > max_bottom )); then
        total_bottom="$max_bottom"
        gpu_lines=3
        mid_lines=$((total_bottom - gpu_lines - 1))

        if (( mid_lines < 3 )); then
            mid_lines=3
            gpu_lines=$((total_bottom - mid_lines - 1))
        fi

        if (( gpu_lines < 2 )); then
            gpu_lines=2
        fi
    fi

    if ! tmux -L "$socket" split-window -v -l "$total_bottom" -t "$session" "$mid_cmd"; then
        echo "[!] tmux 分屏失败，退回原始 docker 模式。" >&2
        tmux -L "$socket" kill-server 2>/dev/null || true
        set -e
        run_original
        return
    fi

    bottom_pane="$(tmux_bottommost_pane "$socket" "$session" || true)"
    [[ -z "$bottom_pane" ]] && bottom_pane="{bottom}"

    if ! tmux -L "$socket" split-window -v -l "$gpu_lines" -t "$session:$bottom_pane" "$gpu_cmd"; then
        echo "[!] tmux 第二次分屏失败，退回原始 docker 模式。" >&2
        tmux -L "$socket" kill-server 2>/dev/null || true
        set -e
        run_original
        return
    fi

    middle_pane="$(tmux_middle_pane "$socket" "$session" || true)"
    bottom_pane="$(tmux_bottommost_pane "$socket" "$session" || true)"

    if [[ -n "$middle_pane" ]]; then
        tmux -L "$socket" resize-pane -t "$session:$middle_pane" -y "$mid_lines" 2>/dev/null || true
    fi

    if [[ -n "$bottom_pane" ]]; then
        tmux -L "$socket" resize-pane -t "$session:$bottom_pane" -y "$gpu_lines" 2>/dev/null || true
    fi

    top_pane="$(tmux_topmost_pane "$socket" "$session" || true)"
    [[ -z "$top_pane" ]] && top_pane="{top}"

    tmux -L "$socket" select-pane -t "$session:$top_pane" 2>/dev/null || true

    tmux -L "$socket" bind-key -n C-c kill-server 2>/dev/null || true
    tmux -L "$socket" bind-key -T copy-mode C-c kill-server 2>/dev/null || true
    tmux -L "$socket" bind-key -T copy-mode-vi C-c kill-server 2>/dev/null || true

    trap "tmux -L '$socket' kill-server 2>/dev/null || true" EXIT
    trap 'exit 0' INT TERM

    tmux -L "$socket" attach -t "$session"
}

case "${1:-}" in
    __top)
        top_mode
        exit $?
        ;;
    __mid)
        mid_mode
        exit $?
        ;;
    __gpu)
        gpu_mode
        exit $?
        ;;
esac

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
    echo "用法1：$0 up|down"
    echo "用法2：$0 up|down CN|tune"
    echo
    echo "说明："
    echo "  默认使用 tmux 三屏："
    echo "    上方：docker compose"
    echo "    中间：nvitop / nvidia-smi"
    echo "    下方：GPU PCIe 链路状态"
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

if [[ -t 1 && $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
    echo "[*] 需要 sudo 权限读取 PCIe 信息，请输入密码。" >&2
    sudo -v || true
fi

if ensure_tmux && [[ -t 1 ]]; then
    start_tmux
else
    if ! [[ -t 1 ]]; then
        echo "[*] 当前不是交互式终端，使用原始 docker 模式。" >&2
    else
        echo "[*] tmux 不可用，使用原始 docker 模式。" >&2
    fi

    run_original
fi
