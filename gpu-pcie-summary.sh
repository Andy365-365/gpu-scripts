#!/usr/bin/env bash
#
# pcie-lanes.sh
#
# 统计 PCIe 设备当前使用通道数、最大能力通道数，以及总和。
#
# 当前通道数来自：
#   lspci -vv 中的 LnkSta: Width xN
#
# 最大能力通道数来自：
#   lspci -vv 中的 LnkCap: Width xN
#
# 默认只统计 endpoint 设备，不包含 PCI bridge / Root Port / PCIe Switch Port。
# 使用 --all 可以统计所有具有 LnkSta 的 PCIe 设备，但会重复计算桥接链路。
#
# 用法：
#   ./pcie-lanes.sh
#   ./pcie-lanes.sh --all
#   ./pcie-lanes.sh --sudo
#   ./pcie-lanes.sh --no-sudo
#

set -u
export LC_ALL=C

MODE="endpoint"
USE_SUDO="auto"

usage() {
  cat <<EOF
用法: $0 [选项]

选项:
  -a, --all        统计并显示所有 PCIe 链路，包括 Root Port / PCI Bridge / PCIe Switch Port。
                   注意：这会重复计算同一物理链路。
  -e, --endpoint   只统计并显示 PCIe endpoint 设备。默认模式。
      --sudo       强制使用 sudo lspci。
      --no-sudo    禁止使用 sudo。
  -h, --help       显示帮助。

示例:
  sudo $0
  sudo $0 --all
  $0 --no-sudo
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--all)
      MODE="all"
      shift
      ;;
    -e|--endpoint)
      MODE="endpoint"
      shift
      ;;
    --sudo)
      USE_SUDO="yes"
      shift
      ;;
    --no-sudo)
      USE_SUDO="no"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[!] 未知参数: $1" >&2
      echo >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! command -v lspci >/dev/null 2>&1; then
  echo "[!] 未找到 lspci，请先安装 pciutils。" >&2
  echo "    Debian/Ubuntu: sudo apt install pciutils" >&2
  echo "    RHEL/CentOS:   sudo yum install pciutils" >&2
  exit 1
fi

# 根据是否 root / 是否允许 sudo，决定 lspci 命令。
if [[ $EUID -eq 0 ]]; then
  LSPCI=(lspci)
else
  case "$USE_SUDO" in
    yes)
      if command -v sudo >/dev/null 2>&1; then
        LSPCI=(sudo lspci)
      else
        echo "[!] 未找到 sudo，将使用普通 lspci，部分信息可能读不到。" >&2
        LSPCI=(lspci)
      fi
      ;;
    no)
      LSPCI=(lspci)
      ;;
    auto)
      if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        LSPCI=(sudo -n lspci)
      else
        LSPCI=(lspci)
      fi
      ;;
    *)
      LSPCI=(lspci)
      ;;
  esac
fi

if [[ $EUID -ne 0 && "${LSPCI[0]}" != "sudo" ]]; then
  echo "[*] 警告: 当前非 root，且未使用 sudo。部分 LnkCap/LnkSta 信息可能读不到。" >&2
  echo "[*] 建议运行: sudo $0" >&2
fi

print_header() {
  printf '%-14s %-6s %-7s %-7s %-10s %s\n' \
    "BDF" "CLASS" "CUR" "MAX" "SPEED" "DEVICE"
  printf '%-14s %-6s %-7s %-7s %-10s %s\n' \
    "--------------" "------" "-------" "-------" "----------" "------"
}

header_printed=0

ep_count=0
ep_cur_sum=0
ep_max_sum=0

all_count=0
all_cur_sum=0
all_max_sum=0

while IFS= read -r line; do
  [[ -z "$line" ]] && continue

  bdf="${line%% *}"
  desc="${line#* }"

  # 从 lspci -D -nn 输出里提取 class code，例如 0300、0604。
  class="$(
    printf '%s' "$line" |
      sed -nE 's/^[^[:space:]]+[[:space:]]+[^[]*\[([0-9a-fA-F]{4})\].*/\1/p'
  )"

  if [[ -z "$class" ]]; then
    class="????"
  fi

  # 读取该设备的详细 PCIe 信息。
  vv="$("${LSPCI[@]}" -s "$bdf" -vv 2>/dev/null)"

  lnksta="$(
    printf '%s\n' "$vv" |
      sed -nE 's/^[[:space:]]*LnkSta:[[:space:]]*//p' |
      head -n1
  )"

  lnkcap="$(
    printf '%s\n' "$vv" |
      sed -nE 's/^[[:space:]]*LnkCap:[[:space:]]*//p' |
      head -n1
  )"

  cur_width="$(
    printf '%s' "$lnksta" |
      sed -nE 's/.*Width x([0-9]+).*/\1/p'
  )"

  cap_width="$(
    printf '%s' "$lnkcap" |
      sed -nE 's/.*Width x([0-9]+).*/\1/p'
  )"

  cur_speed="$(
    printf '%s' "$lnksta" |
      sed -nE 's|.*Speed ([0-9.]+GT/s).*|\1|p'
  )"

  # 没有 LnkSta Width 的设备跳过。
  [[ -z "$cur_width" ]] && continue

  # 判断是否为 bridge / root port / switch port。
  # PCI class 06xx 通常是 bridge 设备，其中 0604 是 PCI bridge。
  is_bridge=0

  if [[ "$class" == 06* ]]; then
    is_bridge=1
  fi

  desc_lower="${desc,,}"
  if [[ "$desc_lower" == *"pci bridge"* ||
        "$desc_lower" == *"pcie bridge"* ||
        "$desc_lower" == *"host bridge"* ]]; then
    is_bridge=1
  fi

  # 所有链路统计。
  all_count=$(( all_count + 1 ))
  all_cur_sum=$(( all_cur_sum + cur_width ))

  cap_for_sum="${cap_width:-$cur_width}"
  all_max_sum=$(( all_max_sum + cap_for_sum ))

  # Endpoint 统计。
  if [[ "$is_bridge" -eq 0 ]]; then
    ep_count=$(( ep_count + 1 ))
    ep_cur_sum=$(( ep_cur_sum + cur_width ))
    ep_max_sum=$(( ep_max_sum + cap_for_sum ))
  fi

  # 是否显示该设备。
  show=0

  if [[ "$MODE" == "all" ]]; then
    show=1
  elif [[ "$is_bridge" -eq 0 ]]; then
    show=1
  fi

  if [[ "$show" -eq 1 ]]; then
    if [[ "$header_printed" -eq 0 ]]; then
      print_header
      header_printed=1
    fi

    printf '%-14s %-6s %-7s %-7s %-10s %s\n' \
      "$bdf" \
      "$class" \
      "x${cur_width}" \
      "x${cap_width:--}" \
      "${cur_speed:--}" \
      "$desc"
  fi

done < <("${LSPCI[@]}" -D -nn 2>/dev/null)

if [[ "$header_printed" -eq 0 ]]; then
  if [[ "$MODE" == "all" ]]; then
    echo "未发现可读取 LnkSta 的 PCIe 设备。"
  else
    echo "未发现可读取 LnkSta 的 PCIe endpoint 设备。"
    echo "可以尝试: $0 --all"
  fi
fi

echo
echo "==================== 统计 ===================="

if [[ "$MODE" == "all" ]]; then
  echo "显示模式: all"
  echo "说明: 包含 Root Port / PCI Bridge / PCIe Switch Port，可能重复计算同一物理链路。"
else
  echo "显示模式: endpoint"
  echo "说明: 默认不包含 Root Port / PCI Bridge / PCIe Switch Port。"
fi

echo

printf 'Endpoint 数量: %s\n' "$ep_count"
printf 'Endpoint 当前 PCIe 通道数之和: %s lanes\n' "$ep_cur_sum"
printf 'Endpoint 最大能力 PCIe 通道数之和: %s lanes\n' "$ep_max_sum"

echo

printf '所有 PCIe 链路数量: %s\n' "$all_count"
printf '所有 PCIe 当前通道数之和: %s lanes\n' "$all_cur_sum"
printf '所有 PCIe 最大能力通道数之和: %s lanes\n' "$all_max_sum"

echo
echo "注意:"
echo "  1. CUR 来自 LnkSta Width，表示当前协商的 PCIe 通道数。"
echo "  2. MAX 来自 LnkCap Width，表示设备支持的最大 PCIe 通道数。"
echo "  3. 如果 MAX 读不到，统计最大能力时会用 CUR 代替。"
echo "  4. 所有 PCIe 链路之和包含桥设备，会重复计算，因此通常只看 endpoint 之和。"
