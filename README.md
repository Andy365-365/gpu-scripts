# gpu-scripts

LuckyStep 工作站（2×RTX 3090）的 GPU 监控与诊断脚本集合。

## 内容

| 脚本 | 说明 |
|------|------|
| `gpu_monitor.py` | 仿 nvitop 风格的实时 GPU 监控 TUI（GPU→PCIe→Process，1 秒无闪烁覆盖刷新）。依赖 `psutil`、`pynvml`。 |
| `template.txt` | `gpu_monitor.py` 的固定布局模板（92 列，槽位锁死）。 |
| `gpu-check.sh` | 精简 GPU 状态一键检查。 |
| `gpu-pcie-summary.sh` | PCIe 链路（Slot/BDF/Speed/Width）汇总。 |
| `gpu-slot-check.sh` | 物理 Slot 与 GPU 对应关系检查。 |
| `gpu-speed-test.sh` | GPU 拷贝/PCIe 带宽速度测试（可配合 `gpu-burn`）。 |
| `gpu-speed-watch.sh` | GPU 带宽速率实时监视。 |
| `docker-gpu.sh` | Docker GPU 容器相关辅助。 |
| `docker-gpu-pcie.sh` | Docker GPU + PCIe 诊断辅助。 |

## 运行

```bash
# 实时监控（Ctrl+C 退出）
python3 gpu_monitor.py

# 只渲染一帧（不依赖真实 GPU）
python3 gpu_monitor.py --demo

# 一键检查
bash gpu-check.sh
```

## 依赖

- `gpu_monitor.py`：Python 3.12+，`psutil`、`pynvml`
- 其余 shell 脚本：`nvidia-smi`、`lspci`、`ps`（标准 Linux 工具）

## 敏感信息

已检查：不含 API key、token、密码、内网 IP 或账号名。仅含工作站品牌名 `LuckyStep`。
