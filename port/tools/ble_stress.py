#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""BLE 连接压力测试：反复连/断 N 次，验证连接槽位不再泄漏。

用法:
    python tools/ble_stress.py            # 默认 15 轮
    python tools/ble_stress.py 30         # 30 轮
    python tools/ble_stress.py 15 COM6     # 同时校验（可选）
"""
from __future__ import annotations

import asyncio
import sys
import time

try:
    from bleak import BleakClient, BleakScanner
except ImportError:
    print("需要 bleak:  pip install bleak")
    sys.exit(2)

SERVICE = "0000ff00-0000-1000-8000-00805f9b34fb"
INFO_UUID = "0000ff03-0000-1000-8000-00805f9b34fb"
NAME = "BTSH-LIGHT"

CONNECT_TIMEOUT = 20.0


def kwargs():
    import platform
    if platform.system() == "Windows":
        return {"winrt": {"use_cached_services": False}}
    return {}


async def find(timeout=8.0):
    """按地址返回第一个符合的 BleakDevice（合并广播，优先厂商数据）。"""
    found = {}

    def cb(dev, adv):
        md = getattr(adv, "manufacturer_data", None) or {}
        ok_mfr = any(len(v) == 4 and v[0] == 1 and v[1] == 1 and 1 <= v[2] <= 32
                     and not (v[3] & ~0x07) for v in md.values())
        nm = getattr(adv, "local_name", None) or dev.name or ""
        if ok_mfr or NAME.lower() in nm.lower():
            found.setdefault(dev.address, dev)

    async with BleakScanner(detection_callback=cb):
        await asyncio.sleep(timeout)
    return next(iter(found.values()), None) if found else None


async def one_cycle(dev, idx, total):
    t0 = time.time()
    try:
        async with BleakClient(dev, timeout=CONNECT_TIMEOUT, **kwargs()) as c:
            data = await c.read_gatt_char(INFO_UUID)
            dt = time.time() - t0
            ok = bytes(data)[:2] == b"\x01\x01"
            print(f"  [{idx:2}/{total}] {'✅' if ok else '❌'} 连接+读信息 "
                  f"{bytes(data).hex(' '):8}  {dt*1000:.0f} ms")
            return ok
    except Exception as e:
        print(f"  [{idx:2}/{total}] ❌ {type(e).__name__}: {str(e)[:70]}")
        return False


async def main(n):
    print("=" * 56)
    print(f" 连接压力测试：连续 {n} 次 连接→读信息→断开")
    print("=" * 56)

    ok = fail = 0
    first_fail = None
    for i in range(1, n + 1):
        # 扫描偶尔会漏掉一次广播，重试几次（这不是板子的问题）
        dev = None
        for attempt in range(3):
            dev = await find(4.0 if attempt == 0 else 6.0)
            if dev is not None:
                break
        if dev is None:
            print(f"  [{i:2}/{n}] ❌ 扫描 3 次都找不到设备（可能已经拒绝新连接）")
            fail += 1
            first_fail = first_fail or i
            continue
        if await one_cycle(dev, i, n):
            ok += 1
        else:
            fail += 1
            first_fail = first_fail or i
        await asyncio.sleep(0.8)   # 给板子时间重新广播

    print("-" * 56)
    print(f"  成功 {ok} / {n}   失败 {fail}")
    if fail == 0:
        print("  ✅ 全部成功：连接槽位没有泄漏")
    else:
        print(f"  ❌ 首次失败在第 {first_fail} 次")
        print("     若失败集中在第 N 次之后，说明仍存在槽位泄漏")
    print("=" * 56)
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 15
    try:
        sys.exit(asyncio.run(main(n)))
    except KeyboardInterrupt:
        print("\n中断")
        sys.exit(130)
