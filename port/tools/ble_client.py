#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BTSH-LIGHT  BLE 上位机 / 测试工具
=================================

用途
----
1. 板子烧好固件后，**在 PC 上立刻验证 BLE 链路**（不用等 A7Z、不用手机 App）。
2. 作为 **A7Z 侧 central 实现的参考代码** —— 协议时序、UUID、字节格式都在这里。

协议（详见 port/BLE_PROTOCOL_A7Z.md）
------------------------------------
    服务   0xFF00
    0xFF01 WRITE          1 字节  0x00=关灯 0x01=开灯        ← 旧协议，仍支持
                          4 字节  [index, R, G, B]           ← 逐灯 RGB
                                  index 0..4 = 第几颗灯，0xFF = 全部
    0xFF02 READ + NOTIFY  1 字节  0x00/0x01（有任意一颗亮即为 01）
    0xFF03 READ           3 字节  01 01 00  (协议版本/通道数/保留)

用法
----
    pip install bleak

    python ble_client.py --scan              # 扫描，找 BTSH-LIGHT
    python ble_client.py --info              # 读设备信息（应得 01 01 00）
    python ble_client.py --on                # 开灯（全部绿色）
    python ble_client.py --off               # 关灯
    python ble_client.py --state             # 读当前状态
    python ble_client.py --watch 30          # 订阅通知，实时打印
    python ble_client.py --selftest          # 跑一遍完整自检序列

    # 逐灯 RGB
    python ble_client.py --rgb 0 64 0 0      # 第 1 颗设为红色
    python ble_client.py --rgb 255 0 0 64    # 全部设为蓝色
    python ble_client.py --rainbow           # 每颗不同颜色，验证逐灯寻址

    # 设备名/地址可覆盖
    python ble_client.py --name BTSH-LIGHT-A1F2 --on
    python ble_client.py --address AA:BB:CC:DD:EE:FF --on

注意
----
* 板子启动后需在 NSH 里执行 `btsh_light start` 才会广播。
* Windows 需要蓝牙适配器；Linux 需要 BlueZ 且当前用户在 bluetooth 组。
"""

from __future__ import annotations

import argparse
import asyncio
import sys

try:
    from bleak import BleakClient, BleakScanner
except ImportError:
    sys.exit("缺少 bleak，请先执行:  pip install bleak")

# ---------------------------------------------------------------------------
# 协议常量  —— A7Z 侧照抄这一段即可
# ---------------------------------------------------------------------------

BTSH_SERVICE_UUID = "0000ff00-0000-1000-8000-00805f9b34fb"
BTSH_CMD_UUID     = "0000ff01-0000-1000-8000-00805f9b34fb"   # WRITE
BTSH_STATE_UUID   = "0000ff02-0000-1000-8000-00805f9b34fb"   # READ + NOTIFY
BTSH_INFO_UUID    = "0000ff03-0000-1000-8000-00805f9b34fb"   # READ

CMD_OFF = 0x00
CMD_ON  = 0x01

# 4 字节 RGB 写入时 index 的特殊值：整条灯带
RGB_ALL = 0xFF
# 板上有几颗灯（与固件 CONFIG_BTSH_LIGHT_LED_COUNT 一致）
LED_COUNT = 5

DEFAULT_NAME = "BTSH-LIGHT"


# ---------------------------------------------------------------------------
# 设备发现
# ---------------------------------------------------------------------------

async def find_device(name: str, address: str | None, timeout: float = 8.0):
    """返回 (BleakDevice, adv_data)；找不到返回 (None, None)。"""

    if address:
        print(f"按地址连接 {address} ...")
        return address, None

    print(f"扫描 {timeout:.0f}s，查找 '{name}' ...")
    found = {}

    def cb(dev, adv):
        dev_name = adv.local_name or dev.name
        if dev_name and name.lower() in dev_name.lower():
            found[dev.address] = (dev, adv)

    async with BleakScanner(detection_callback=cb):
        await asyncio.sleep(timeout)

    if not found:
        return None, None

    addr, (dev, adv) = next(iter(found.items()))
    print(f"找到 {dev.name}  [{addr}]  RSSI={adv.rssi}")
    return dev, adv


# ---------------------------------------------------------------------------
# 操作
# ---------------------------------------------------------------------------

async def cmd_info(client: BleakClient):
    data = await client.read_gatt_char(BTSH_INFO_UUID)
    b = bytes(data)
    print(f"设备信息: {b.hex(' ')}   (原始 {len(b)} 字节)")
    if len(b) >= 2:
        print(f"  协议版本 : {b[0]}")
        print(f"  通道数   : {b[1]}")
    if b[:2] == b"\x01\x01":
        print("  ✅ 对端是 BTSH 灯控，协议匹配")
    else:
        print("  ⚠️ 协议字段不是期望的 01 01")
    return b


async def cmd_state(client: BleakClient):
    data = await client.read_gatt_char(BTSH_STATE_UUID)
    b = bytes(data)
    s = "ON" if (b and b[0] == CMD_ON) else "OFF"
    print(f"灯状态: {b.hex(' ')}  -> {s}")
    return b


async def cmd_write(client: BleakClient, value: int):
    await client.write_gatt_char(BTSH_CMD_UUID, bytes([value]), response=True)
    print(f"已写入 0xFF01 = 0x{value:02x}  ({'开灯' if value else '关灯'})")
    await asyncio.sleep(0.3)
    await cmd_state(client)


async def cmd_rgb(client: BleakClient, idx: int, r: int, g: int, b: int,
                  readback: bool = True):
    """4 字节写入：[index, R, G, B]；index=0xFF 表示整条灯带。"""
    await client.write_gatt_char(BTSH_CMD_UUID, bytes([idx, r, g, b]),
                                 response=True)
    where = "全部" if idx == RGB_ALL else f"第 {idx + 1} 颗"
    print(f"已写入 RGB: {where} = ({r}, {g}, {b})")
    if readback:
        await asyncio.sleep(0.3)
        await cmd_state(client)


async def cmd_rainbow(client: BleakClient, brightness: int = 48):
    """每颗灯一个颜色，用来一眼确认逐灯寻址正确。"""
    cols = [
        ("红", brightness, 0, 0),
        ("绿", 0, brightness, 0),
        ("蓝", 0, 0, brightness),
        ("黄", brightness, brightness, 0),
        ("紫", brightness, 0, brightness),
    ]
    for i in range(min(LED_COUNT, len(cols))):
        name, r, g, b = cols[i]
        await client.write_gatt_char(BTSH_CMD_UUID, bytes([i, r, g, b]),
                                     response=True)
        print(f"  第 {i + 1} 颗 -> {name} ({r},{g},{b})")
        await asyncio.sleep(0.15)
    await cmd_state(client)


async def cmd_watch(client: BleakClient, seconds: float):
    def on_notify(_char, data: bytearray):
        b = bytes(data)
        print(f"  [notify] {b.hex(' ')}  -> {'ON' if b[:1] == bytes([CMD_ON]) else 'OFF'}")

    await client.start_notify(BTSH_STATE_UUID, on_notify)
    print(f"已订阅 0xFF02 通知，监听 {seconds:.0f}s（期间可在 NSH 里改状态或写入 0xFF01）...")
    await asyncio.sleep(seconds)
    await client.stop_notify(BTSH_STATE_UUID)
    print("停止监听")


async def cmd_selftest(client: BleakClient):
    print("=" * 52)
    print(" 自检序列")
    print("=" * 52)

    ok = True
    info = await cmd_info(client)
    if info[:2] != b"\x01\x01":
        ok = False

    print("\n[1] 订阅通知")
    notes = []
    def on_notify(_c, data: bytearray):
        notes.append(bytes(data))
        print(f"  [notify] {bytes(data).hex(' ')}")
    await client.start_notify(BTSH_STATE_UUID, on_notify)

    print("\n[2] 开灯")
    await cmd_write(client, CMD_ON)
    await asyncio.sleep(0.5)
    s = await cmd_state(client)
    ok &= (s[:1] == bytes([CMD_ON]))

    print("\n[3] 关灯")
    await cmd_write(client, CMD_OFF)
    await asyncio.sleep(0.5)
    s = await cmd_state(client)
    ok &= (s[:1] == bytes([CMD_OFF]))

    print("\n[4] 逐灯 RGB（第 1 颗红 / 第 2 颗绿 / 第 3 颗蓝）")
    for i, (r, g, b) in enumerate([(48, 0, 0), (0, 48, 0), (0, 0, 48)]):
        await cmd_rgb(client, i, r, g, b, readback=False)
        await asyncio.sleep(0.2)
    s = await cmd_state(client)
    # 有灯亮着 -> 聚合状态应为 ON
    ok &= (s[:1] == bytes([CMD_ON]))

    print("\n[5] 全部熄灭")
    await cmd_rgb(client, RGB_ALL, 0, 0, 0, readback=False)
    await asyncio.sleep(0.3)
    s = await cmd_state(client)
    ok &= (s[:1] == bytes([CMD_OFF]))

    await client.stop_notify(BTSH_STATE_UUID)
    print(f"\n[6] 收到 {len(notes)} 条通知")

    print("\n" + "=" * 52)
    print(" 自检结果:", "✅ 全部通过" if ok else "❌ 有失败项")
    print("=" * 52)
    return ok


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

async def run(args):
    if args.scan:
        print(f"扫描 {args.scan:.0f}s ...")
        devs = await BleakScanner.discover(timeout=args.scan)
        if not devs:
            print("没扫到任何 BLE 设备（检查蓝牙适配器）")
            return 0
        for d in sorted(devs, key=lambda x: -(x.rssi or -999)):
            mark = "  <-- BTSH" if (d.name or "").upper().startswith("BTSH") else ""
            print(f"  {d.address}  rssi={d.rssi:4}  {d.name}{mark}")
        return 0

    target, _ = await find_device(args.name, args.address, args.timeout)
    if not target:
        print(f"❌ 没找到 '{args.name}'。检查：")
        print("   1) 板子是否执行了 btsh_light start")
        print("   2) 板子是否上电、BLE 是否初始化成功（看串口日志）")
        return 2

    async with BleakClient(target, timeout=20.0) as client:
        if not client.is_connected:
            print("❌ 连接失败")
            return 3
        print(f"✅ 已连接 {target}\n")

        if args.selftest:
            return 0 if await cmd_selftest(client) else 1
        if args.info:
            await cmd_info(client)
        if args.state:
            await cmd_state(client)
        if args.on:
            await cmd_write(client, CMD_ON)
        if args.off:
            await cmd_write(client, CMD_OFF)
        if args.rgb:
            idx, r, g, b = args.rgb
            await cmd_rgb(client, idx, r, g, b)
        if args.rainbow:
            await cmd_rainbow(client)
        if args.watch:
            await cmd_watch(client, args.watch)
        if not any([args.info, args.state, args.on, args.off, args.rgb,
                    args.rainbow, args.watch]):
            await cmd_info(client)
            await cmd_state(client)

    return 0


def main():
    p = argparse.ArgumentParser(
        description="BTSH-LIGHT BLE 上位机 / 测试工具（也是 A7Z 侧实现参考）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)
    p.add_argument("--name", default=DEFAULT_NAME, help=f"广播名（默认 {DEFAULT_NAME}）")
    p.add_argument("--address", default=None, help="直接指定 MAC，跳过扫描")
    p.add_argument("--timeout", type=float, default=8.0, help="扫描超时秒数")
    p.add_argument("--scan", nargs="?", const=8.0, type=float, metavar="SEC",
                   help="只扫描并列出设备（不带参数默认扫 8 秒）")
    p.add_argument("--info", action="store_true", help="读设备信息 0xFF03")
    p.add_argument("--state", action="store_true", help="读灯状态 0xFF02")
    p.add_argument("--on", action="store_true", help="开灯（写 0xFF01=1）")
    p.add_argument("--off", action="store_true", help="关灯（写 0xFF01=0）")
    p.add_argument("--rgb", nargs=4, type=int, metavar=("IDX", "R", "G", "B"),
                   help="设置某颗灯颜色，IDX=255 表示全部（写 4 字节到 0xFF01）")
    p.add_argument("--rainbow", action="store_true",
                   help="每颗灯一个颜色，确认逐灯寻址")
    p.add_argument("--watch", type=float, metavar="SEC", help="订阅通知并监听 N 秒")
    p.add_argument("--selftest", action="store_true", help="跑完整自检序列")
    args = p.parse_args()

    try:
        sys.exit(asyncio.run(run(args)))
    except KeyboardInterrupt:
        print("\n中断")
        sys.exit(130)


if __name__ == "__main__":
    main()
