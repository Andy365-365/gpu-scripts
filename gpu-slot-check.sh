#!/bin/bash
export TERM=xterm-256color
RED='\x1b[91m'
NC='\x1b[0m'

echo "===== lspci topology ====="
sudo lspci -tv

echo "===== slot info ====="
sudo dmidecode -t slot | sed 's/\(handle\|SLOT\)/\x1b[91m\1\x1b[0m/gI'

echo "===== PCIe link status ====="
dev_list=("00:02.0" "03:00.0" "80:02.0" "84:00.0")
for s in "${dev_list[@]}"; do
  echo "===== $s ====="
  sudo lspci -s "$s" -vv | egrep -i 'LnkCap|LnkSta|LnkCtl|DevSta' | sed -E "s/(LnkCap|LnkSta|LnkCtl|DevSta)/${RED}\1${NC}/gI"
done

echo "===== nvidia-smi PCIe ====="
nvidia-smi --query-gpu=pci.bus_id,name,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max --format=csv | sed -E "s/(pcie|gen|width)/${RED}\1${NC}/gI"

echo "===== PCIe/AER errors ====="
dmesg -T | egrep -i 'AER|PCIe Bus Error|link down|bandwidth|0000:03:00.0|0000:84:00.0|0000:00:02.0|0000:80:02.0' | sed -E "s/(AER|PCIe Bus Error|link down|bandwidth|0000:03:00.0|0000:84:00.0|0000:00:02.0|0000:80:02.0)/${RED}\1${NC}/gI"
