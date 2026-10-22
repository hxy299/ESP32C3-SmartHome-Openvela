#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
串口日志记录器（断线自动重连）
==============================

专门用来抓 ESP32-C3 的启动日志。普通串口助手（miniterm/PuTTY）在设备
重新枚举时会崩掉并丢失日志，这个工具会自动重连并继续记录。

用法:
    python serial_log.py                      # 自动找 COM 口
    python serial_log.py -p COM6              # 指定端口
    python serial_log.py -b 115200 -o boot.txt
    python serial_log.py --list               # 只列出可用串口

退出: Ctrl+C

提示:
    * 启动本工具后，再按 SW2(EN) 复位板子。
    * 日志同时打印到屏幕并写入文件（默认 boot.log）。
    * 设备消失时它会打印 [断开]，然后每 0.5s 重新查找端口。
"""

from __future__ import annotations   # 让 Python 3.7-3.9 也能用 `str | None` 注解

import argparse
import sys
import time

try:
    import serial
    from serial.tools import list_ports
except ImportError:
    sys.exit("缺少 pyserial，请先执行:  pip install pyserial")


def find_port(hint: str | None):
    """找一个可能是 ESP32 的串口。"""
    ports = list(list_ports.comports())
    if hint:
        for p in ports:
            if p.device.upper() == hint.upper():
                return p.device
        return None

    # 优先选描述里带 USB/JTAG/CP210/CH34/ESP 的
    keys = ("JTAG", "USB", "CP210", "CH340", "CH910", "ESP", "Serial")
    for p in sorted(ports, key=lambda x: x.device):
        desc = f"{p.description or ''} {p.manufacturer or ''}"
        if any(k.lower() in desc.lower() for k in keys):
            return p.device
    return None


def main():
    ap = argparse.ArgumentParser(description="ESP32-C3 串口日志记录器（自动重连）")
    ap.add_argument("-p", "--port", default=None, help="端口名，如 COM6；不填则自动查找")
    ap.add_argument("-b", "--baud", type=int, default=115200)
    ap.add_argument("-o", "--out", default="boot.log", help="日志文件（默认 boot.log）")
    ap.add_argument("--list", action="store_true", help="只列出串口后退出")
    args = ap.parse_args()

    if args.list:
        ports = list(list_ports.comports())
        if not ports:
            print("没有找到任何串口")
        for p in ports:
            print(f"  {p.device:8}  {p.description}")
        return 0

    logf = open(args.out, "ab", buffering=0)
    print(f"日志写入: {args.out}")
    print("现在可以按 SW2(EN) 复位板子。Ctrl+C 退出。\n")

    tries = 0
    while True:
        port = find_port(args.port)
        if not port:
            if tries % 4 == 0:
                print(f"[等待] 找不到端口{f' {args.port}' if args.port else ''} ...")
            tries += 1
            time.sleep(0.5)
            continue

        try:
            with serial.Serial(port, args.baud, timeout=0.2) as ser:
                print(f"[连上] {port} @ {args.baud}")
                t_open = time.time()
                linebuf = []

                # 【重要】绝对不要动 DTR/RTS：
                # ESP32-C3 的 USB-Serial-JTAG 把 DTR/RTS 电平变化当作复位请求
                # （esptool 正是靠这个进下载模式）。一旦拨动，板子就会
                # 以 rst:0x15 (USB_UART_CHIP_RESET) 反复重启。
                #
                # 同理不要做"静默 N 秒就重开串口"——重开也会触发复位。

                while True:
                    n = ser.in_waiting
                    data = ser.read(n if n else 1)
                    if data:
                        # 加时间戳：判断"断开"是连接后几毫秒还是几秒，
                        # 这对定位 BLE 掉线原因至关重要。
                        text = data.decode("utf-8", "replace")
                        for ch in text:
                            if ch == "\n":
                                sys.stdout.write("\n")
                                linebuf.clear()
                            else:
                                linebuf.append(ch)
                                if len(linebuf) == 1 and ch != "\r":
                                    sys.stdout.write(f"[{time.time() - t_open:7.3f}s] ")
                                sys.stdout.write(ch)
                        sys.stdout.flush()
                        logf.write(data)
        except KeyboardInterrupt:
            print("\n[退出]")
            logf.close()
            return 0
        except Exception as e:
            print(f"\n[断开] {type(e).__name__}: {e}")
            print("[重连] 等待设备重新枚举 ...")
            time.sleep(0.5)


if __name__ == "__main__":
    sys.exit(main())
