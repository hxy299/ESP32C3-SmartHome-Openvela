#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""向串口发命令并打印回应（用于验证 nsh 控制台是否可输入）。

用法：
    python tools/serial_cmd.py -p COM6                    # 只发一个回车，看有没有 nsh> 回应
    python tools/serial_cmd.py -p COM6 -c "help"
    python tools/serial_cmd.py -p COM6 -c "btsh_light state" -w 3

注意：打开串口会让板子复位（ESP32-C3 把 DTR/RTS 变化当复位信号），
      所以脚本会先等启动日志出现，再发命令。
"""
from __future__ import annotations

import argparse
import sys
import time

try:
    import serial
except ImportError:
    print("需要 pyserial:  pip install pyserial")
    sys.exit(2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-p", "--port", required=True, help="串口，如 COM6")
    ap.add_argument("-b", "--baud", type=int, default=115200)
    ap.add_argument("-c", "--cmd", default="", help="要发送的命令（默认只发回车）")
    ap.add_argument("-w", "--wait", type=float, default=4.0, help="等启动日志的秒数")
    ap.add_argument("--no-crlf", action="store_true", help="命令末尾不自动加 \\r")
    args = ap.parse_args()

    # dsrdtr/rtscts 保持关闭；打开后不要主动碰 DTR/RTS
    ser = serial.Serial(args.port, args.baud, timeout=0.2,
                        rtscts=False, dsrdtr=False)

    boot = bytearray()
    t0 = time.time()
    got_prompt = False
    while time.time() - t0 < args.wait:
        d = ser.read(256)
        if d:
            boot += d
            if b"nsh>" in boot:
                got_prompt = True
                break

    print("=== 启动日志 ===")
    print(boot.decode("utf-8", "replace").strip() or "(无)")

    if not got_prompt:
        print("\n⚠️  没等到 nsh> 提示符")

    payload = args.cmd.encode()
    if not args.no_crlf:
        payload += b"\r"

    print(f"\n=== 发送 {len(payload)} 字节: {payload!r} ===")
    ser.write(payload)
    ser.flush()

    # 收集回应
    resp = bytearray()
    t1 = time.time()
    idle = 0.0
    while time.time() - t1 < 6.0:
        d = ser.read(256)
        if d:
            resp += d
            idle = 0.0
        else:
            idle += 0.1
            if idle > 1.2 and resp:
                break

    print("=== 回应 ===")
    text = resp.decode("utf-8", "replace")
    print(text.strip() or "(无回应)")

    # 判定
    echo_ok = args.cmd and args.cmd.encode() in resp
    prompt_ok = b"nsh>" in resp
    print("\n=== 判定 ===")
    print(f"  命令被回显 : {'✅' if echo_ok else '❌'}")
    print(f"  收到提示符 : {'✅' if prompt_ok else '❌'}")
    if echo_ok or prompt_ok:
        print("  ✅ 控制台可以输入")
    else:
        print("  ❌ 控制台仍不可输入（RX 通路有问题）")

    ser.close()
    return 0 if (echo_ok or prompt_ok) else 1


if __name__ == "__main__":
    sys.exit(main())
