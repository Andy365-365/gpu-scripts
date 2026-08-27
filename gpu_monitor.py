#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gpu_monitor.py — 仿 nvitop 风格的 GPU 监控（1 秒无闪烁覆盖刷新）

布局严格按用户提供的模板 /root/template.txt 填充：
  - 每个 [] 槽位宽度锁死（与模板一致），真实值按槽宽格式化填入，超宽截断，
    整行总宽恒为 94（顶栏 91，无框线不扩），不随数据变化。
  - TIME 列 = 墙钟运行时长（ps -o etime，nvitop 的 TIME 含义），完整显示 HH:MM:SS。
  - PCIe lnk 左对齐，长降级行也装在固定 94 宽内。

数据源（每帧并行采集，单帧 <1s）：
  nvidia-smi / pmon / query-compute-apps / ps / lspci -vv / /proc/{stat,meminfo}

颜色（与 ./gpu-check.sh 一致）：
  Temp 红(>=80) 黄(>=60) 绿(其余)；PCIe LnkSta 含 (downgraded) → 橙(38;5;208)，否则亮绿

用法：
  python3 gpu_monitor.py            # 持续刷新，Ctrl+C 退出
  python3 gpu_monitor.py --frames 3 # 只跑 3 帧
  python3 gpu_monitor.py --demo     # 固定数据渲染一帧（不依赖真实 GPU）
"""
import re
import signal
import subprocess
import sys
import time
import threading
from concurrent.futures import ThreadPoolExecutor

import psutil
import pynvml as nvml

# ===== NVML 初始化（%SM 直读，替代 pmon，与 nvitop 同源）=====
_nvml_lock = threading.Lock()
_nvml_warned = False  # 主循环兜底：采集异常只告警一次（stderr），不刷屏
# _nvml_fail_streak = 0  # 原连续失败计数：曾配合"连续10次异常"stderr 提示，
# 该提示已注释（无数据时 SM/GMBW 显示 0，无需提示；且 TUI 原地刷新下
# stderr 提示会与帧输出交错，行首被覆盖成 "u_monitor] NVML ..." 缺前缀）。
_proc_cache = {}  # pid -> psutil.Process（复用对象才能维持 cpu_percent 的跨帧缓存）
nvml.nvmlInit()

# ===== 颜色 =====
RESET  = "\033[0m"
RED    = "\033[91m"
YELLOW = "\033[93m"
GREEN  = "\033[92m"
CYAN    = "\033[96m"
MAGENTA = "\033[95m"
ORANGE  = "\033[38;5;208m"

# ===== ANSI 光标控制 =====
SAVE_CUR    = "\033[s"
RESTORE_CUR = "\033[u"
CLR_LINE    = "\033[K"

# ===== 模板固定行（总宽 94；右边界由 93 右移 1 列，中间分栏位置不变）=====
TOP = "╒" + "═" * 92 + "╕"
G_SEP1 = "├" + "─" * 40 + "┬" + "─" * 23 + "┬" + "─" * 27 + "┤"
G_HDR  = "│ GPU   Fan   Temp   Perf   Pwr:Usg/Cap  │     Memory-Usage      │ GPU-Util  Compute M.      │"
G_SEP2 = "╞" + "═" * 40 + "╪" + "═" * 23 + "╪" + "═" * 27 + "╡"
G_MID  = "├" + "─" * 40 + "┼" + "─" * 23 + "┼" + "─" * 27 + "┤"
G_END  = "╞" + "═" * 40 + "╧" + "═" * 23 + "╧" + "═" * 27 + "╡"
P_HDR  = "│ GPU     PID     USER    GPU-MEM   %SM   %GMBW  %CPU   %MEM  TIME       COMMAND             │"
P_TOP  = "╞" + "═" * 92 + "╡"
P_MID  = "├" + "─" * 92 + "┤"
P_END  = "╞" + "═" * 92 + "╡"
C_HDR  = "│ SLOT  PCIE    GC-Clock  GM-Clock  MC-Clock  MM-Clock  LINK SPEED                           │"
C_TOP  = "╞" + "═" * 92 + "╡"
C_MID  = "├" + "─" * 92 + "┤"
C_END  = "╘" + "═" * 92 + "╛"

# ===== 数据行模板（[ ] 为槽位；填充时 [ ] 各自替换成一个空格，值填入中间，行宽恒定 94）=====
GPU_T  = "│ [0] [ 90%]  [74C]  [P2]  [288W / 300W] │ [23.20GiB / 24.00GiB] │  [ 44%]    [Default]      │"
PROC_T = "│ [0]  [10847 C] [root] [ 23.18GiB][ 46]  [ 37][ 68.9] [2.6] [01:44:59] [VLLM::Worker_TP0]   │"
TOP_T  = "[Sun Aug 23 12:11:44 2026]                                     CPU: [ 7.5% ] MEM: [ 9.7% ] "
TITLE_T = "│<LuckyStep v1.0.0>      Driver Version: [610.43.02]           CUDA Driver Version: [13.3]   │"
# PCIe 行统一用「长行」版固定模板：lnk 槽最宽（可装下最长降级行），短 lnk 左对齐补齐
PCI_T  = "│ [4] [84:00.0][1.50GHz] [2.10GHz] [9.40GHz] [9.70GHz] [2.5GT/s (downgraded) x8 (downgraded)]│"

ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def strip_ansi(s):
    return ANSI.sub("", s)


def pad(s, w, al):
    """把 s 按可视宽对齐到 w（ANSI 色码不占宽）；超长按对齐方向截断到 w。返回可视宽恰为 w。"""
    vis = len(strip_ansi(s))
    if vis == w:
        return s
    if vis > w:
        t = strip_ansi(s)
        return t[-w:] if al == "r" else t[:w]
    sp = " " * (w - vis)
    return (sp + s) if al == "r" else (s + sp)


def _vw(s):
    """可视宽度（ANSI 色码不占宽）。"""
    return len(strip_ansi(s))


def fill(tmpl, pairs):
    """把模板每个 [..] 槽替换为「空格 + 值(按槽宽对齐) + 空格」，替换串可视长度=原槽宽，整行宽度恒定。
    对齐方向从槽内容推断：以内侧空格开头 → 右对齐，否则左对齐。
    右对齐槽值区宽 = 前导空格 + 核心值区（如 '[ 44%]' 宽 4，填 '100%' 得 ' 100%' 不截断）。
    左对齐槽值区宽 = 核心值区（如 '[4    ]' 值区宽 1）。
    全程按可视宽度对齐，值可带 ANSI 色码（CPU/MEM/PCIe downgraded）。"""
    it = iter(pairs)

    def rep(m):
        val = next(it)
        inner = m.group(1)
        lead = len(inner) - len(inner.lstrip(" "))    # 前导空格（右对齐时 = padding 量）
        trail = len(inner) - len(inner.rstrip(" "))   # 尾部空格（固定保留）
        core = len(inner.strip(" "))                  # 核心值区宽
        width = lead + core if lead else core         # 值需占满的可视宽度
        vw = _vw(val)
        if vw <= width:
            pad_n = width - vw
            body = (" " * pad_n + val) if lead else (val + " " * pad_n)
        else:  # 超宽：按可视宽截断（丢弃色码，取可见部分）
            plain = strip_ansi(val)
            body = plain[-width:] if lead else plain[:width]
        return " " + body + " " * trail + " "

    return re.sub(r"\[([^\]]*)\]", rep, tmpl)


def fmt_time(etime):
    """ps etime（[[dd-]hh:]mm:ss）→ 恒定 8 位 HH:MM:SS；≥99h 取末 8 位。"""
    s = (etime or "").strip()
    if not s:
        return "00:00:00"
    days = 0
    if "-" in s:
        d, s = s.split("-", 1)
        days = int(d)
    parts = s.split(":")
    if len(parts) == 3:
        h, m, sec = (int(x) for x in parts)
    elif len(parts) == 2:
        h, m, sec = 0, int(parts[0]), int(parts[1])
    else:
        return s[-8:]
    h += days * 24
    return f"{h:02d}:{m:02d}:{sec:02d}"[-8:]


def nvitop_row_color(gpu_util, mem_pct):
    """nvitop 第一部分配色：整行 = max(显存档, GPU档)；显存阈值(10,80)，GPU阈值(10,75)。"""
    def lv(v, th):
        if v >= th[1]:
            return 2
        if v >= th[0]:
            return 1
        return 0
    lvl = max(lv(gpu_util, (10, 75)), lv(mem_pct, (10, 80)))
    return {0: GREEN, 1: YELLOW, 2: RED}[lvl]


def color_temp(t):
    if t is None:
        return GREEN
    return RED if t >= 80 else (YELLOW if t >= 60 else GREEN)


def render(d):
    rows = []
    # 顶栏：CPU 亮青 / MEM 亮粉，标签文字与数值一起染色（同 nvitop）
    top = fill(TOP_T, [d["date"], f"{d['cpu']:.1f}%", f"{d['mem']:.1f}%"])
    top = re.sub(r"CPU: \s*[\d.]+%", lambda m: CYAN + m.group(0) + RESET, top)
    top = re.sub(r"MEM: \s*[\d.]+%", lambda m: MAGENTA + m.group(0) + RESET, top)
    top += RESET  # 行尾空格不染
    rows.append(top)
    # 标题框
    rows.append(TOP)
    rows.append(fill(TITLE_T, [d["driver"], d["cuda"]]))
    # GPU 主表
    rows.append(G_SEP1)
    rows.append(G_HDR)
    rows.append(G_SEP2)
    gpus = d["gpus"]
    for i, g in enumerate(gpus):
        mem_pct = (g["mu"] / g["mt"] * 100.0) if g["mt"] else 0.0
        line = fill(GPU_T, [
            f"{g['idx']}",
            g["fan"],
            f"{g['temp']}C",
            g["pstate"],
            f"{g['pwr']}W / {g['plim']}W",
            f"{g['mu']:.2f}GiB / {g['mt']:.2f}GiB",
            f"{g['util']}%",
            g["cm"],
        ])
        inner = line[1:-1]  # 去掉首尾 │ 边框
        segs = inner.split("│")  # 三段数据，中间两条竖线不染色
        c = nvitop_row_color(g["util"], mem_pct)
        rows.append("│" + c + segs[0] + RESET + "│" + c + segs[1] + RESET
                    + "│" + c + segs[2] + RESET + "│")
        rows.append(G_END if i == len(gpus) - 1 else G_MID)
    # PCIe 表
    rows.append(C_HDR)
    rows.append(C_TOP)
    pcis = d["pcis"]
    for i, pc in enumerate(pcis):
        degraded = "downgraded" in pc["lnk"].lower()
        lnk = (ORANGE + pc["lnk"] + RESET) if degraded else (GREEN + pc["lnk"] + RESET)
        gc_val = f"{pc['gc']/1000:.2f}GHz"
        gc_c = RED if pc.get("thr") else GREEN
        gc = (gc_c + gc_val + RESET)
        rows.append(fill(PCI_T, [
            pc["slot"], pc["bdf"],
            gc, f"{pc['gm']/1000:.2f}GHz",
            f"{pc['mc']/1000:.2f}GHz", f"{pc['mm']/1000:.2f}GHz", lnk,
        ]))
        rows.append(P_END if i == len(pcis) - 1 else C_MID)
    if not pcis:
        rows.append(P_END)
    # 进程表
    rows.append(P_HDR)
    rows.append(P_TOP)
    procs = d["procs"]
    for i, p in enumerate(procs):
        t = fmt_time(p["time"])
        rows.append(fill(PROC_T, [
            f"{p['gpu']}",
            f"{p['pid']} {p['ty']}",
            p["user"],
            p["mem"],
            f"{p['sm']}",
            f"{p['bw']}",
            f"{p['cpu']:.1f}",
            f"{p['mem_']:.1f}",
            t,
            p["cmd"],
        ]))
        if procs:
            rows.append(C_END if i == len(procs) - 1 else P_MID)
    if not procs:
        rows.append(C_END)
    return rows


# ===== 采集 =====
def run(cmd, timeout=5):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True,
                              text=True, timeout=timeout).stdout
    except Exception:
        return ""


def query_gpus():
    # fan_speed 在该驱动上会让整条 query 失败，故不在此查询；fan 由 get_fans_and_version() 补。
    f = ("--query-gpu=index,temperature.gpu,pstate,power.draw,power.limit,"
         "utilization.gpu,memory.used,memory.total,pci.bus_id,"
         "clocks.current.graphics,clocks.max.graphics,"
         "clocks.current.memory,clocks.max.memory,"
         "clocks_throttle_reasons.active")
    out = strip_ansi(run(f"nvidia-smi {f} --format=csv,noheader"))
    gpus = []
    for line in out.splitlines():
        if not line.strip():
            continue
        p = [x.strip() for x in line.split(",")]
        if len(p) < 14:
            continue
        gpus.append({
            "idx": int(p[0]),
            "temp": int(float(p[1])),
            "pstate": p[2],
            "pwr": int(round(float(p[3].replace("W", "").strip()))),
            "plim": int(round(float(p[4].replace("W", "").strip()))),
            "util": int(p[5].replace("%", "").strip()),
            "mu": int(p[6].split()[0]) / 1024.0,
            "mt": int(p[7].split()[0]) / 1024.0,
            "fan": "[N/A]",
            "bdf": p[8].split(":")[-2] + ":" + p[8].split(":")[-1],
            "cm": "Default",
            "gc": int(float(p[9].split()[0])),
            "gm": int(float(p[10].split()[0])),
            "mc": int(float(p[11].split()[0])),
            "mm": int(float(p[12].split()[0])),
            # 0x60 = SW Thermal(0x20) | HW Thermal(0x40)，任一热降频激活 → True
            # 位定义见 nvml.h：SwPowerCap=0x4 HwSlowdown=0x8 SyncBoost=0x10
            #          SwThermal=0x20 HwThermal=0x40 HwPowerBrake=0x80(不含)
            "thr": (int(p[13], 16) & 0x60) != 0,
        })
    return gpus


def get_fans_and_version():
    out = strip_ansi(run("nvidia-smi"))
    fans, drv, cud = {}, "?", "?"
    lines = out.splitlines()
    for i, ln in enumerate(lines):
        m = re.match(r"^\|\s*(\d+)\s+\S", ln)
        if m and i + 1 < len(lines):
            fm = re.match(r"^\|\s*(\d+%)?\s", lines[i + 1])
            if fm and fm.group(1):
                fans[int(m.group(1))] = fm.group(1)
        m = re.search(r"NVIDIA-SMI\s+([\d.]+)", ln)
        if m:
            drv = m.group(1)
        m = re.search(r"CUDA UMD Version:\s*([\d.]+)", ln)
        if m:
            cud = m.group(1)
    return fans, drv, cud


def get_pci(bdfs):
    def one(bdf):
        o = run(f"lspci -vv -s {bdf}")
        slot = "0"
        m = re.search(r"Physical Slot:\s*(\S+)", o)
        if m:
            slot = m.group(1)
        lnk = ""
        m = re.search(r"LnkSta:\s*(.*)", o)
        if m:
            lnk = m.group(1).strip()
            lnk = re.sub(r"^Speed\s+", "", lnk)
            lnk = re.sub(r",\s*Width\s+", " ", lnk)
        return bdf, slot, lnk
    out = {}
    if bdfs:
        with ThreadPoolExecutor(max_workers=max(1, len(bdfs))) as ex:
            for bdf, slot, lnk in ex.map(one, bdfs):
                out[bdf] = {"slot": slot, "bdf": bdf, "lnk": lnk}
    return out


def get_procs():
    def parse_ps():
        # etime = 墙钟运行时长（nvitop 的 TIME 含义），格式 [[dd-]hh:]mm:ss
        # 注意：不用 ps 的 pcpu（它是整个生命周期的平均值，几乎不动），
        # %CPU 改用 psutil.Process.cpu_percent() 的刷新窗口增量（同 nvitop）
        o = run("ps -eo pid,user,pmem,etime,comm")
        r = {}
        for ln in o.splitlines():
            m = re.match(r"^\s*(\d+)\s+(\S+)\s+([\d.]+)\s+(\S+)\s+(.*)$", ln)
            if m:
                r[int(m.group(1))] = {"user": m.group(2),
                                      "mem": float(m.group(3)), "time": m.group(4),
                                      "comm": m.group(5)}
        return r

    def parse_apps():
        o = strip_ansi(run("nvidia-smi --query-compute-apps=pid,used_memory,process_name"
                          " --format=csv,noheader"))
        r = {}
        for ln in o.splitlines():
            p = [x.strip() for x in ln.split(",")]
            if len(p) >= 3:
                mm = re.match(r"(\d+)", p[1])
                if mm:
                    r[int(p[0])] = {"mem": f"{int(mm.group(1)) / 1024.0:.2f}GiB", "cmd": p[2]}
        return r

    def nvml_gpu_util():
        # 直读 NVML 每进程 SM/显存利用率（同 nvitop：api/device.py
        # libnvml.nvmlQuery('nvmlDeviceGetProcessUtilization', ...,
        # timeStamp=now-1s, default=())）。
        # 注意：NVMLError_NotFound 是正常返回——采样窗口内没有新记录
        # （GPU 空闲/进程不活跃）驱动返回 NOT_FOUND，nvitop 用 default=()
        # 把它当空列表处理。pynvml 包成了异常，这里按空采样处理：
        # 不计数、不告警，缺采样的进程由调用方填 0（同 nvitop）。
        # （原"连续失败计数 + 提示一次"逻辑整体注释掉，原因见函数开头。）
        r = {}
        with _nvml_lock:
            ts = time.time_ns() // 1000 - 1_000_000  # 1 秒前（同 nvitop）
            for idx in range(nvml.nvmlDeviceGetCount()):
                h = nvml.nvmlDeviceGetHandleByIndex(idx)
                try:
                    samples = nvml.nvmlDeviceGetProcessUtilization(h,
                                                                  timeStamp=ts)
                except nvml.NVMLError:
                    # 无采样 = 正常空闲，静默跳过（SM/BW 由调用方填 0）。
                    # 原连续失败计数与提示逻辑：
                    # _nvml_fail_streak += 1
                    # if _nvml_fail_streak == 10:
                    #     print("[gpu_monitor] NVML 进程利用率连续 10 次异常，"
                    #           "进程表 SM/GMBW 可能缺数据", file=sys.stderr)
                    continue
                # 原 _nvml_fail_streak = 0
                for s in samples:
                    r[(idx, s.pid)] = (s.smUtil, s.memUtil)
        return r

    def running_procs():
        # 进程表主键（同 nvitop：Compute + Graphics 两类全列出），
        # 返回 {(gpu_idx, pid): type_char}
        r = {}
        with _nvml_lock:
            for idx in range(nvml.nvmlDeviceGetCount()):
                h = nvml.nvmlDeviceGetHandleByIndex(idx)
                for ty, func in (("C", nvml.nvmlDeviceGetComputeRunningProcesses),
                                 ("G", nvml.nvmlDeviceGetGraphicsRunningProcesses)):
                    try:
                        ps_ = func(h)
                    except nvml.NVMLError:
                        continue
                    for p in ps_:
                        r[(idx, p.pid)] = ty
        return r

    def psutil_cpu(pid):
        # %CPU = 上次刷新 → 本次的窗口增量（1Hz 即 1 秒窗口，与 nvitop 同款）。
        # 首次调用建立基线返回 0.0，之后每帧调用取增量。
        try:
            p = _proc_cache.get(pid)
            if p is None:
                p = psutil.Process(pid)
                _proc_cache[pid] = p
                p.cpu_percent()  # 建立基线
                return 0.0
            return p.cpu_percent()
        except psutil.NoSuchProcess:
            _proc_cache.pop(pid, None)
            return 0.0

    ps, ap, gu, keys = parse_ps(), parse_apps(), nvml_gpu_util(), running_procs()
    procs = []
    # 主键 = Compute+Graphics 运行进程（同 nvitop）；采样只补 SM/BW，
    # 没有采样的进程（窗口内不活跃）SM/BW 填 0，行照样显示（同 nvitop）
    for (gpu, pid), ty in keys.items():
        sm, bw = gu.get((gpu, pid), (0, 0))
        s = ps.get(pid, {})
        a = ap.get(pid, {})
        procs.append({
            "gpu": gpu, "pid": pid, "ty": ty,
            "user": s.get("user", "?"),
            "mem": a.get("mem", "?"),
            "sm": sm, "bw": bw,
            "cpu": psutil_cpu(pid), "mem_": s.get("mem", 0.0),
            "time": s.get("time", "-"),
            "cmd": a.get("cmd", s.get("comm", "?")),
        })
    procs.sort(key=lambda p: (p["gpu"], p["pid"]))
    return procs


def cpu_percent():
    # 与 nvitop 同款：psutil.cpu_percent()，取「上次调用 → 本次」区间平均（0.5s 窗口）
    return psutil.cpu_percent()


def mem_percent():
    with open("/proc/meminfo") as f:
        v = {}
        for ln in f:
            p = ln.split()
            v[p[0].rstrip(":")] = int(p[1])
    return 100.0 * (v["MemTotal"] - v["MemAvailable"]) / v["MemTotal"]


# 数据缓存：对齐 nvitop 默认刷新节奏（1080 宽逐帧抓屏实测）——
# 顶栏(日期/CPU/MEM) 1s/次、GPU 主表 2s、进程表 2s
_cache = {"gpus": None, "pcis": {}, "drv": None, "cud": None,
          "procs": None, "host": (0.0, 0.0),
          "last_gpu": -1e9, "last_proc": -1e9, "last_host": -1e9}


def collect():
    t0 = time.time()
    now = t0
    need_gpu = now - _cache["last_gpu"] >= 2.0
    need_proc = now - _cache["last_proc"] >= 2.0
    need_host = now - _cache["last_host"] >= 1.0  # 顶栏 1s（对齐 nvitop 日期行）
    with ThreadPoolExecutor(max_workers=4) as ex:
        f_m = ex.submit(mem_percent) if need_host else None
        f_c = ex.submit(cpu_percent) if need_host else None
        f_g = ex.submit(query_gpus) if need_gpu else None
        f_f = ex.submit(get_fans_and_version) if need_gpu else None
        f_p = ex.submit(get_procs) if need_proc else None
    if need_host:
        mp, cp = f_m.result(), f_c.result()
        _cache["host"] = (mp, cp)
        _cache["last_host"] = now
    else:
        mp, cp = _cache["host"]
    if need_gpu:
        gpus, (fans, drv, cud) = f_g.result(), f_f.result()
        for g in gpus:
            if g["idx"] in fans:
                g["fan"] = fans[g["idx"]]
        pcis = get_pci([g["bdf"] for g in gpus])
        _cache.update(gpus=gpus, pcis=pcis, drv=drv, cud=cud, last_gpu=now)
    else:
        gpus, drv, cud, pcis = _cache["gpus"], _cache["drv"], _cache["cud"], _cache["pcis"]
    if need_proc:
        _cache["procs"] = f_p.result()
        _cache["last_proc"] = now
    procs = _cache["procs"]
    return {
        "date": time.strftime("%a %b %d %H:%M:%S %Y"),
        "cpu": cp, "mem": mp,
        "driver": drv, "cuda": cud,
        "gpus": gpus, "procs": procs,
        "pcis": [
            {**pcis[g["bdf"]], "gc": g["gc"], "gm": g["gm"],
             "mc": g["mc"], "mm": g["mm"], "thr": g["thr"]}
            for g in gpus if g["bdf"] in pcis
        ],
        "elapsed": time.time() - t0,
    }


def demo_data():
    return {
        "date": "Sun Aug 23 12:11:44 2026",
        "cpu": 7.5, "mem": 9.7,
        "driver": "610.43.02", "cuda": "13.3",
        "gpus": [
            {"idx": 0, "temp": 74, "pstate": "P2", "pwr": 288, "plim": 300, "util": 44, "mu": 23.20, "mt": 24.0, "fan": "90%", "bdf": "03:00.0", "cm": "Default"},
            {"idx": 1, "temp": 92, "pstate": "P2", "pwr": 241, "plim": 300, "util": 85, "mu": 23.20, "mt": 24.0, "fan": "100%", "bdf": "84:00.0", "cm": "Default"},
        ],
        "procs": [
            {"gpu": 0, "pid": 10847, "ty": "C", "user": "root", "mem": "23.18GiB", "sm": 46, "bw": 37, "cpu": 68.9, "mem_": 2.6, "time": "01:44:59", "cmd": "VLLM::Worker_TP0"},
            {"gpu": 1, "pid": 10911, "ty": "C", "user": "root", "mem": "23.18GiB", "sm": 87, "bw": 37, "cpu": 68.4, "mem_": 2.6, "time": "01:44:10", "cmd": "VLLM::Worker_TP1"},
        ],
        "pcis": [
            {"slot": "6", "bdf": "03:00.0", "lnk": "2.5GT/s (downgraded) x16",
             "gc": 1400, "gm": 2100, "mc": 9500, "mm": 9700, "thr": False},
            {"slot": "4", "bdf": "84:00.0", "lnk": "2.5GT/s (downgraded) x8 (downgraded)",
             "gc": 1500, "gm": 2100, "mc": 9400, "mm": 9700, "thr": True},
        ],
        "elapsed": 0.0,
    }


def term_size():
    """终端尺寸 (rows, cols)；非 TTY 返回 None。"""
    try:
        import fcntl
        import struct
        import termios
        return struct.unpack("hh", fcntl.ioctl(1, termios.TIOCGWINSZ,
                                               b"0" * 4))
    except Exception:
        return None


def main():
    global _nvml_warned
    args = sys.argv[1:]
    frames = None
    if "--frames" in args:
        frames = int(args[args.index("--frames") + 1])
    demo = "--demo" in args

    if demo:
        print("\n".join(render(demo_data())))
        return

    signal.signal(signal.SIGINT, lambda *a: sys.exit(0))
    psutil.cpu_percent(None)  # 初始化：psutil 首次调用无历史，先建立基线
    prev_size = term_size()
    height = 0  # 高度水印：至今最大行数。原地刷新靠它补空行（带 CLR_LINE）
              # 清除当前帧没覆盖到的旧行——进程表变空/容器关闭时行数缩短，
              # 不补的话旧行直接裸露在屏幕上
    try:
        n = 0
        while True:
            try:
                d = collect()
            except Exception as e:
                # 采集异常不崩屏：跳过本帧（NVML 幽灵条目、进程消失等瞬时错误）
                if not _nvml_warned:
                    print(f"[gpu_monitor] 采集异常({type(e).__name__}: {e})，跳过本帧",
                          file=sys.stderr)
                _nvml_warned = True
                time.sleep(0.5)
                continue
            _nvml_warned = False  # 本帧正常，复位告警标志
            rows = render(d)
            # 窗口尺寸变化 → 先整屏清再重绘，避免残留；旧内容已清，水印重置
            size = term_size()
            if size is not None and size != prev_size:
                sys.stdout.write("\033[2J\033[1;1H")
                sys.stdout.flush()
                prev_size = size
                height = len(rows)
            # 补空行到水印高度（空行同样带 CLR_LINE），清除当前帧未覆盖的旧行
            height = max(height, len(rows))
            if size is not None:
                height = min(height, max(size[0], 1))  # 不超终端高度，防整屏上滚
            for i in range(len(rows), height):
                rows.append("")
            # 面板锚定在屏幕顶部（第 1 行）：每帧回到第 1 行原地重绘
            # 行与行之间才换行，末行不加 \n，避免顶出屏底触发整屏上滚
            out = "\033[1;1H" + "\n".join(r + CLR_LINE for r in rows)
            sys.stdout.write(out)
            sys.stdout.flush()
            n += 1
            if frames is not None and n >= frames:
                break
            time.sleep(max(0.0, 0.5 - d["elapsed"]))
    finally:
        # 退出：定位到第 1 行，清掉面板区域到屏底
        sys.stdout.write("\033[1;1H\033[J" + RESET)
        sys.stdout.flush()


if __name__ == "__main__":
    main()
