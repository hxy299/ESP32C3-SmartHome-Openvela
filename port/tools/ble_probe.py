#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BLE 连接诊断探针
================

比 ble_client.py 更啰嗦，专门用来定位"扫得到但连不上/服务发现超时"。

它会打印：
    * 连接前后 is_connected 的真实状态
    * 断线事件（谁断的、什么时候断的、错误码）
    * GATT 服务/特征逐个列出
    * 分阶段计时，看是哪一步超时

用法:
    python ble_probe.py                    # 自动找 BTSH-LIGHT
    python ble_probe.py -n BTSH-LIGHT
    python ble_probe.py -a DC:DA:0C:82:B8:6E   # 直接给地址
"""

from __future__ import annotations

import argparse
import asyncio
import sys
import time
import traceback

try:
    from bleak import BleakClient, BleakScanner
except ImportError:
    sys.exit("缺少 bleak，请先执行:  pip install bleak")

DISCONNECTED = []
T0 = time.time()


def ts() -> str:
    return f"[{time.time() - T0:6.2f}s]"


def on_disconnect(client):
    DISCONNECTED.append(time.time())
    print(f"{ts()} ⚠️ 收到断开事件 (is_connected={client.is_connected})")


async def find(name: str, addr: str | None, timeout: float):
    if addr:
        print(f"{ts()} 使用指定地址 {addr}")
        return addr

    print(f"{ts()} 扫描 {timeout:.0f}s 查找 '{name}' ...")
    found = {}

    def cb(dev, adv):
        n = adv.local_name or dev.name
        if n and name.lower() in n.lower():
            found[dev.address] = (dev, adv)

    async with BleakScanner(detection_callback=cb):
        await asyncio.sleep(timeout)

    if not found:
        return None
    a, (dev, adv) = next(iter(found.items()))
    print(f"{ts()} 找到 {dev.name} [{a}] RSSI={adv.rssi}")
    return dev


async def probe(args):
    target = await find(args.name, args.address, args.timeout)
    if not target:
        print("❌ 没找到设备")
        return 2

    print(f"\n{ts()} === 阶段 1：建立连接 ===")
    client = BleakClient(target, timeout=args.connect_timeout,
                         disconnected_callback=on_disconnect)
    try:
        t = time.time()
        await asyncio.wait_for(client.connect(), timeout=args.connect_timeout)
        print(f"{ts()} connect() 返回，耗时 {time.time() - t:.2f}s，"
              f"is_connected={client.is_connected}")
    except asyncio.TimeoutError:
        print(f"{ts()} ❌ connect() 超时（{args.connect_timeout}s），"
              f"is_connected={client.is_connected}")
        return 3
    except Exception as e:
        print(f"{ts()} ❌ connect() 异常: {type(e).__name__}: {e}")
        return 3

    # 立刻看连接是否还活着
    print(f"\n{ts()} === 阶段 2：连接稳定性（等 {args.settle}s）===")
    for i in range(int(args.settle * 2)):
        await asyncio.sleep(0.5)
        print(f"{ts()}   is_connected={client.is_connected}"
              f"  断开次数={len(DISCONNECTED)}")
        if not client.is_connected:
            print(f"{ts()} ❌ 连接已断开")
            break

    print(f"\n{ts()} === 阶段 3：GATT 服务发现 ===")
    try:
        t = time.time()
        services = await asyncio.wait_for(client.get_services(),
                                          timeout=args.svc_timeout)
        print(f"{ts()} ✅ 服务发现成功，耗时 {time.time() - t:.2f}s")
        for s in services:
            print(f"   service {s.uuid}")
            for c in s.characteristics:
                print(f"      char {c.uuid}  props={','.join(c.properties)}")
    except asyncio.TimeoutError:
        print(f"{ts()} ❌ 服务发现超时（{args.svc_timeout}s）")
        print(f"   此时 is_connected={client.is_connected}，"
              f"断开次数={len(DISCONNECTED)}")
        print("   → 若仍 connected：说明对端不回 ATT 请求")
        print("   → 若已断开：说明对端在连接后立刻断了")
        rc = 4
    except Exception as e:
        print(f"{ts()} ❌ 服务发现异常: {type(e).__name__}: {e}")
        traceback.print_exc()
        rc = 4
    else:
        rc = 0

    try:
        await client.disconnect()
        print(f"{ts()} 已主动断开")
    except Exception:
        pass

    print(f"\n{ts()} === 汇总 ===")
    print(f"  断开事件次数: {len(DISCONNECTED)}")
    return rc


def main():
    ap = argparse.ArgumentParser(description="BLE 连接诊断探针")
    ap.add_argument("-n", "--name", default="BTSH-LIGHT")
    ap.add_argument("-a", "--address", default=None)
    ap.add_argument("-t", "--timeout", type=float, default=8.0, help="扫描秒数")
    ap.add_argument("-c", "--connect-timeout", type=float, default=15.0)
    ap.add_argument("-s", "--svc-timeout", type=float, default=15.0)
    ap.add_argument("--settle", type=float, default=3.0, help="连接后观察几秒")
    args = ap.parse_args()
    try:
        sys.exit(asyncio.run(probe(args)))
    except KeyboardInterrupt:
        print("\n中断")
        sys.exit(130)


if __name__ == "__main__":
    main()
