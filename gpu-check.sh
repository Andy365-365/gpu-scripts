#!/bin/bash
# 精简GPU状态一键检查

# ===== 字符定义 =====
TL='┌'; TR='┐'; BL='└'; BR='┘'
H='─'; V='│'
TJ_UP='┬'; TJ_DN='┴'; TJ_L='├'; TJ_R='┤'; CROSS='┼'

# ===== 工具函数 =====
center() {
    local text="$1" width="$2"
    local len=${#text}
    local pad=$(( (width - len) / 2 ))
    local pad_right=$(( width - len - pad ))
    printf "%${pad}s%s%${pad_right}s" "" "$text" ""
}

trim() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}

# ===== 显卡基础信息 =====
echo "=== 显卡基础信息 ==="

nvidia-smi --query-gpu=index,name,pci.bus_id,memory.total,power.draw,temperature.gpu --format=csv,noheader | while IFS=, read idx nm bus mem pwr temp; do
    idx=$(echo "$idx" | xargs)
    nm=$(echo "$nm" | xargs)
    bus=$(echo "$bus" | xargs)
    mem=$(echo "$mem" | xargs)
    pwr=$(echo "$pwr" | xargs)
    temp=$(echo "$temp" | xargs)
    sb=${bus#00000000:}
    sta=$(lspci -vv -s "$sb" 2>/dev/null | grep "LnkSta:" | head -1 | sed 's/.*LnkSta:[[:space:]]*//' | sed 's/[[:space:]]*$//')
    slot=$(lspci -vv -s "$sb" 2>/dev/null | grep "Physical Slot" | awk '{print $3}')
    [ -z "$slot" ] && slot=$(dmidecode -t slot 2>/dev/null | awk -v x="$sb" '/Bus Address:/{if($3==x)print d} /Designation:/{d=$2" "$3}')
    [ -z "$slot" ] && slot="未知"
    echo "$slot|$idx|$nm|$sb|$mem|$pwr|$temp|$sta"
done > /tmp/_gpu_rows.txt

# 按 Slot 序号排序
sort -t'|' -k1,1n /tmp/_gpu_rows.txt -o /tmp/_gpu_rows.txt

HEADER=("Slot" "ID" "Name" "PCI" "Memory" "Power" "Temp" "PCIe Link")
COL_W=(4 2 4 8 8 8 4 6)

while IFS='|' read s0 s1 s2 s3 s4 s5 s6 s7; do
    FIELDS=("$s0" "$s1" "$s2" "$s3" "$s4" "$s5" "$s6" "$s7")
    for i in 0 1 2 3 4 5 6 7; do
        w=${#FIELDS[$i]}
        [ $w -gt ${COL_W[$i]} ] && COL_W[$i]=$w
    done
done < /tmp/_gpu_rows.txt
for i in 0 1 2 3 4 5 6 7; do
    w=${#HEADER[$i]}
    [ $w -gt ${COL_W[$i]} ] && COL_W[$i]=$w
done

# 分隔线
make_sep() {
    local lj="$1" cj="$2" rc="$3"
    printf '%s' "$lj"
    for i in 0 1 2 3 4 5 6 7; do
        local w=$((COL_W[i] + 2))
        local seg=""
        for ((j=0; j<w; j++)); do seg+="$H"; done
        if [ $i -lt 7 ]; then printf '%s%s' "$seg" "$cj"
        else printf '%s%s' "$seg" "$rc"; fi
    done
    printf '\n'
}

make_sep "$TL" "$TJ_UP" "$TR"

printf '%s' "$V"
for i in 0 1 2 3 4 5 6 7; do
    printf ' %-*s %s' "${COL_W[i]}" "${HEADER[i]}" "$V"
done
printf '\n'

make_sep "$TJ_L" "$CROSS" "$TJ_R"

while IFS='|' read s0 s1 s2 s3 s4 s5 s6 s7; do
    p0=$(printf "%-${COL_W[0]}s" "$s0")
    p1=$(printf "%-${COL_W[1]}s" "$s1")
    p2=$(printf "%-${COL_W[2]}s" "$s2")
    p3=$(printf "%-${COL_W[3]}s" "$s3")
    p4=$(printf "%-${COL_W[4]}s" "$s4")
    p5=$(printf "%-${COL_W[5]}s" "$s5")
    p6=$(printf "%-${COL_W[6]}s" "$s6")
    p7=$(printf "%-${COL_W[7]}s" "$s7")

    tval=${s6// /}
    if [ "$tval" -ge 80 ] 2>/dev/null; then
        p6=$'\033[91m'"$p6"$'\033[0m'
    elif [ "$tval" -ge 60 ] 2>/dev/null; then
        p6=$'\033[93m'"$p6"$'\033[0m'
    else
        p6=$'\033[92m'"$p6"$'\033[0m'
    fi

    if echo "$s7" | grep -qi "downgraded"; then
        p7=$'\033[38;5;208m'"$p7"$'\033[0m'
    fi

    printf '%s %b %b %b %b %b %b %b %b %b %b %b %b %b %b %b %s\n' \
        "$V" "$p0" "$V" "$p1" "$V" "$p2" "$V" "$p3" \
        "$V" "$p4" "$V" "$p5" "$V" "$p6" "$V" "$p7" "$V"
done < /tmp/_gpu_rows.txt

make_sep "$BL" "$TJ_DN" "$BR"
rm -f /tmp/_gpu_rows.txt

# ===== NVLink 拓扑 =====

echo -e "\n=== NVLink 拓扑 ==="

TOPO_TMP="/tmp/_gpu_topo.txt"
nvidia-smi topo -m | sed '/^Legend:/,$d' | sed '/^[[:space:]]*$/d' | sed 's/\x1b\[[0-9;]*m//g' | sed ':a;s/\t\t/\t/g;ta' | sed 's/\t*$//' | sed 's/\t/|/g' > "$TOPO_TMP"

TOPO_COLS=$(head -1 "$TOPO_TMP" | awk -F'|' '{print NF}')

TOPO_W=()
for ((c=0; c<TOPO_COLS; c++)); do TOPO_W[$c]=0; done
while IFS='|' read -ra cols; do
    for ((c=0; c<${#cols[@]}; c++)); do
        v=$(trim "${cols[$c]}")
        w=${#v}
        [ "$w" -gt "${TOPO_W[$c]}" ] && TOPO_W[$c]=$w
    done
done < "$TOPO_TMP"

print_topo_sep() {
    local lc="$1" cj="$2" rc="$3"
    printf '%s' "$lc"
    for ((c=0; c<TOPO_COLS; c++)); do
        local seg=""
        for ((j=0; j<TOPO_W[c]+2; j++)); do seg+="$H"; done
        if [ $c -lt $((TOPO_COLS-1)) ]; then printf '%s%s' "$seg" "$cj"
        else printf '%s%s' "$seg" "$rc"; fi
    done
    printf '\n'
}

print_topo_row() {
    local line="$1"
    IFS='|' read -ra cols <<< "$line"
    printf '%s' "$V"
    for ((c=0; c<TOPO_COLS; c++)); do
        val=$(trim "${cols[$c]:-}")
        printf ' %s %s' "$(center "$val" "${TOPO_W[c]}")" "$V"
    done
    printf '\n'
}

print_topo_sep "$TL" "$TJ_UP" "$TR"
print_topo_row "$(head -1 "$TOPO_TMP")"
print_topo_sep "$TJ_L" "$CROSS" "$TJ_R"
tail -n +2 "$TOPO_TMP" | while IFS= read -r line; do
    print_topo_row "$line"
done
print_topo_sep "$BL" "$TJ_DN" "$BR"
rm -f "$TOPO_TMP"

# ===== NVLink 链路状态 =====

echo -e "\n=== NVLink 链路状态 ==="

NVLINK_TMP="/tmp/_gpu_nvlink.txt"
nvidia-smi nvlink --status 2>&1 > "$NVLINK_TMP"

LINK_HDR=("Link 0" "Link 1" "Link 2" "Link 3")
NVL_W=()

print_nvlink_table() {
    local vals=("$@")

    NVL_W=()
    for ((c=0; c<4; c++)); do
        local hw=${#LINK_HDR[$c]}
        local vw=${#vals[$c]}
        local m=$hw
        [ "$vw" -gt "$m" ] && m=$vw
        NVL_W[$c]=$m
    done

    printf '%s' "$TL"
    for ((c=0; c<4; c++)); do
        local seg=""
        for ((j=0; j<NVL_W[c]+2; j++)); do seg+="$H"; done
        if [ $c -lt 3 ]; then printf '%s%s' "$seg" "$TJ_UP"
        else printf '%s%s' "$seg" "$TR"; fi
    done
    printf '\n'

    printf '%s' "$V"
    for ((c=0; c<4; c++)); do
        printf ' %s %s' "$(center "${LINK_HDR[$c]}" "${NVL_W[$c]}")" "$V"
    done
    printf '\n'

    printf '%s' "$TJ_L"
    for ((c=0; c<4; c++)); do
        local seg=""
        for ((j=0; j<NVL_W[c]+2; j++)); do seg+="$H"; done
        if [ $c -lt 3 ]; then printf '%s%s' "$seg" "$CROSS"
        else printf '%s%s' "$seg" "$TJ_R"; fi
    done
    printf '\n'

    printf '%s' "$V"
    for ((c=0; c<4; c++)); do
        printf ' %s %s' "$(center "${vals[$c]}" "${NVL_W[$c]}")" "$V"
    done
    printf '\n'

    printf '%s' "$BL"
    for ((c=0; c<4; c++)); do
        local seg=""
        for ((j=0; j<NVL_W[c]+2; j++)); do seg+="$H"; done
        if [ $c -lt 3 ]; then printf '%s%s' "$seg" "$TJ_DN"
        else printf '%s%s' "$seg" "$BR"; fi
    done
    printf '\n'
}

GPU_NAME=""
LINK_VALS=()

GPU_FULL=""
LINK_VALS=()

while IFS= read -r line; do
    if [[ "$line" =~ ^GPU\ [0-9] ]]; then
        if [ ${#LINK_VALS[@]} -eq 4 ]; then
            echo "$GPU_FULL"
            print_nvlink_table "${LINK_VALS[@]}"
            echo
        fi
        GPU_FULL="$line"
        LINK_VALS=()
    elif [[ "$line" =~ "Link" ]]; then
        val=$(echo "$line" | grep -oP '[\d.]+ GB/s')
        LINK_VALS+=("$val")
    fi
done < "$NVLINK_TMP"

if [ ${#LINK_VALS[@]} -eq 4 ]; then
    echo "$GPU_FULL"
    print_nvlink_table "${LINK_VALS[@]}"
fi

rm -f "$NVLINK_TMP"

# ===== 全部显卡PCI设备 =====

echo -e "\n=== 全部显卡PCI设备 ==="

LS_TMP="/tmp/_gpu_lspci.txt"
lspci | grep -E "VGA|3D" > "$LS_TMP"

LS_COLS=2
LS_W=()
for ((c=0; c<LS_COLS; c++)); do LS_W[$c]=0; done

# Parse: Slot|Device (去掉 Class)
LS_PIPE_TMP="/tmp/_gpu_lspci_pipe.txt"
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    left="${line%%: *}"
    right="${line#*: }"
    [[ "$left" == "$line" ]] && continue
    slot="${left%% *}"
    right=$(trim "$right")
    echo "${slot}|${right}"
done < "$LS_TMP" > "$LS_PIPE_TMP"

while IFS='|' read -ra cols; do
    for ((c=0; c<${#cols[@]}; c++)); do
        v=$(trim "${cols[$c]}")
        w=${#v}
        [ "$w" -gt "${LS_W[$c]}" ] && LS_W[$c]=$w
    done
done < "$LS_PIPE_TMP"

HEADER_LS=("Slot" "Device")
for ((c=0; c<2; c++)); do
    w=${#HEADER_LS[$c]}
    [ "$w" -gt "${LS_W[$c]}" ] && LS_W[$c]=$w
done

print_ls_sep() {
    local lc="$1" cj="$2" rc="$3"
    printf '%s' "$lc"
    for ((c=0; c<2; c++)); do
        local seg=""
        for ((j=0; j<LS_W[c]+2; j++)); do seg+="$H"; done
        if [ $c -lt 1 ]; then printf '%s%s' "$seg" "$cj"
        else printf '%s%s' "$seg" "$rc"; fi
    done
    printf '\n'
}

print_ls_row() {
    local line="$1"
    IFS='|' read -ra cols <<< "$line"
    printf '%s' "$V"
    # Slot 居中，Device 左对齐
    printf ' %s %s' "$(center "${cols[0]:-}" "${LS_W[0]}")" "$V"
    printf ' %-*s %s' "${LS_W[1]}" "${cols[1]:-}" "$V"
    printf '\n'
}

print_ls_sep "$TL" "$TJ_UP" "$TR"
print_ls_row "Slot|Device"
print_ls_sep "$TJ_L" "$CROSS" "$TJ_R"
while IFS= read -r line; do
    print_ls_row "$line"
done < "$LS_PIPE_TMP"
print_ls_sep "$BL" "$TJ_DN" "$BR"

rm -f "$LS_TMP" "$LS_PIPE_TMP"