#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""交互式串口终端（可以在 nsh> 里敲命令）。

用法：
    python tools/console.py -p COM6
    python tools/console.py -p COM6 -b 115200

退出：
    Ctrl+C   或   输入 Ctrl+]（0x1d）

说明：
    serial_log.py 是**只读**的日志工具（为了保证绝不触发复位，它不写串口，
    所以你在那个窗口敲键盘不会有任何反应）。
    要在 nsh> 里敲命令，请用本工具。
"""
from __future__ import annotations

import argparse
import sys
import threading

try:
    import serial
except ImportError:
    print("需要 pyserial:  pip install pyserial")
    sys.exit(2)

STOP = threading.Event()


def reader(ser: "serial.Serial"):
    """串口 -> 屏幕"""
    while not STOP.is_set():
        try:
            data = ser.read(256)
        except Exception as e:
            if not STOP.is_set():
                print(f"\n[串口错误] {e}")
            break
        if data:
            sys.stdout.write(data.decode("utf-8", "replace"))
            sys.stdout.flush()


def writer(ser: "serial.Serial"):
    """键盘 -> 串口"""
    while not STOP.is_set():
        try:
            line = sys.stdin.readline()
        except Exception:
            break
        if not line:
            break
        if "\x1d" in line:            # Ctrl+]
            break
        try:
            ser.write(line.encode())
            ser.flush()
        except Exception as e:
            print(f"\n[写入失败] {e}")
            break
    STOP.set()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-p", "--port", required=True, help="串口，如 COM6")
    ap.add_argument("-b", "--baud", type=int, default=115200)
    args = ap.parse_args()

    ser = serial.Serial(args.port, args.baud, timeout=0.2,
                        rtscts=False, dsrdtr=False)

    print(f"[已连接] {args.port} @ {args.baud}")
    print("[提示] 现在可以直接敲 nsh 命令（例如 help、btsh_light state）")
    print("[提示] Ctrl+C 或 Ctrl+] 退出\n")
    print("-" * 56)

    t = threading.Thread(target=reader, args=(ser,), daemon=True)
    t.start()

    try:
        writer(ser)
    except KeyboardInterrupt:
        pass
    finally:
        STOP.set()
        t.join(timeout=1.0)
        ser.close()
        print("\n" + "-" * 56)
        print("[已断开]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
