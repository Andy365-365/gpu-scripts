#!/usr/bin/env bash
set -u

# ========================= 配置区 =========================
# while true; do   sudo lspci -s 03:00.0 -vv | grep -i 'LnkSta:' | head -1;   sudo lspci -s 84:00.0 -vv | grep -i 'LnkSta:' | head -1;   echo ----;   sleep 1; done

# 通过关键词过滤 PCIe 设备，默认查找 3090
GPU_KEYWORD="${GPU_KEYWORD:-3090}"

# 刷新间隔，单位秒
INTERVAL="${INTERVAL:-1}"

# 手动 BDF -> SLOT 强制映射，优先级最高。
# 如果自动识别的 SLOT 不对，请在这里填写。
# 示例：
SLOT_OVERRIDES=()
# SLOT_OVERRIDES=(
#   "03:00.0|6"
#   "84:00.0|7"
# )

# =========================================================

if ! command -v lspci >/dev/null 2>&1; then
  echo "[!] 未找到 lspci，请先安装 pciutils。" >&2
  exit 1
fi

# 如果已经是 root，就直接 lspci；否则使用 sudo -n lspci。
if [[ $EUID -eq 0 ]]; then
  LSPCI=(lspci)
else
  if ! command -v sudo >/dev/null 2>&1; then
    echo "[!] 当前不是 root，且没有 sudo，部分 PCIe 信息可能读不到。" >&2
    LSPCI=(lspci)
  else
    echo "[*] 需要 sudo 权限读取 PCIe 信息，请输入密码。" >&2
    sudo -v || exit 1
    LSPCI=(sudo -n lspci)
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

  # 1. 手动强制映射最高优先
  if slot="$(get_slot_override "$bdf_short" "$bdf_full")"; then
    printf '%s' "$slot"
    return 0
  fi

  # 2. /sys/bus/pci/slots，匹配设备自己
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

  # 3. /sys/bus/pci/slots，匹配上游 bridge / root port
  while IFS= read -r ancestor; do
    [[ -z "$ancestor" ]] && continue

    if slot="$(sysfs_slot_by_address "$ancestor")"; then
      printf '%s' "$slot"
      return 0
    fi
  done < <(get_pci_ancestors "$bdf_short" "$bdf_full" || true)

  # 4. lspci Physical Slot，设备自己
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

  # 5. lspci Physical Slot，上游 bridge / root port
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

  # 尽量贴近之前格式：
  #   LnkSta: Speed 2.5GT/s (downgraded), width x16
  status=$(printf '%s' "$raw" |
    sed -E 's/Width/width/g; s/[[:space:]]*\(ok\)//g; s/[[:space:]]+$//')

  printf 'LnkSta: %s' "$status"
}

detect_devices() {
  local raw_lines=()
  local line bdf_full bdf_short slot

  if [[ -z "$GPU_KEYWORD" ]]; then
    echo "[!] GPU_KEYWORD 为空，无法过滤 PCIe 设备。" >&2
    return 1
  fi

  # 优先匹配显卡设备：
  #   [0300] VGA compatible controller
  #   [0302] 3D controller
  mapfile -t raw_lines < <(
    "${LSPCI[@]}" -D -nn 2>/dev/null |
      grep -i -- "$GPU_KEYWORD" |
      grep -Ei '\[0300\]|\[0302\]|VGA compatible controller|3D controller' || true
  )

  # 如果上面没匹配到，退回普通关键词匹配
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

  echo "[*] 根据关键词 '$GPU_KEYWORD' 找到以下 PCIe 设备:" >&2

  for line in "${raw_lines[@]}"; do
    [[ -z "$line" ]] && continue

    bdf_full="${line%% *}"
    [[ -z "$bdf_full" ]] && continue

    bdf_short="$(normalize_pci_bdf "$bdf_full")"
    slot="$(resolve_slot "$bdf_short" "$bdf_full")"

    DEV_SHORT+=("$bdf_short")
    DEV_SLOT+=("$slot")
    DEV_FULL+=("$bdf_full")

    printf '    BDF %-12s SLOT %-5s %s\n' \
      "$bdf_short" "$slot" "${line#* }" >&2
  done

  if [[ ${#DEV_FULL[@]} -eq 0 ]]; then
    return 1
  fi

  return 0
}

if ! detect_devices; then
  echo "[!] 未找到包含关键词 '$GPU_KEYWORD' 的 PCIe 设备。" >&2
  exit 1
fi

trap 'exit 0' INT TERM

while true; do
  ts="$(date '+%Y-%m-%d %H:%M:%S')"

  for i in "${!DEV_FULL[@]}"; do
    link="$(get_link_status "${DEV_FULL[i]}")"

    printf '[%s] SLOT %s → BDF %s → %s\n' \
      "$ts" \
      "${DEV_SLOT[i]}" \
      "${DEV_SHORT[i]}" \
      "$link"
  done

  echo "----"

  sleep "$INTERVAL"
done