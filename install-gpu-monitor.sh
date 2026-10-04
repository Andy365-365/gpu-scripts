#!/bin/sh
# install-gpu-monitor.sh — 把本仓库的 gpu_monitor.py 包装为全局 gpu-monitor 命令
#
# 用法:
#   sh install-gpu-monitor.sh                 # 安装到 /usr/local/bin/gpu-monitor
#   sh install-gpu-monitor.sh /path/to/bin    # 安装到自定义目录（目录不存在会自动创建）
#
# 行为: 生成一个极薄的 shell wrapper（exec python3 <本仓库>/gpu_monitor.py "$@"），
# 直接执行仓库内的原始文件（不是拷贝），所以 git pull 更新后命令立即生效。
# 重复执行幂等（直接覆盖旧 wrapper）。

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PY="$SCRIPT_DIR/gpu_monitor.py"
# 参数视为目录（不存在也自动创建）；无参数默认 /usr/local/bin
BIN_DIR="${1:-/usr/local/bin}"
TARGET="$BIN_DIR/gpu-monitor"

if [ ! -f "$PY" ]; then
    echo "错误: 找不到 $PY" >&2
    exit 1
fi

# 目标目录不存在则创建（需要写权限，通常要 root）
if [ ! -d "$(dirname -- "$TARGET")" ]; then
    mkdir -p "$(dirname -- "$TARGET")"
fi

cat > "$TARGET" <<EOF
#!/bin/sh
exec /usr/bin/python3 "$PY" "\$@"
EOF
chmod +x "$TARGET"

echo "已安装: $TARGET -> $PY"
