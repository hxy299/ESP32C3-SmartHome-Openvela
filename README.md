# ESP32C3-SmartHome-Openvela

把 **openvela（NuttX 分支）** 移植到 **ESP32-C3-WROOM-02-N4**，做成一块
**5 颗 WS2812B 的 BLE 智能氛围灯**（DogKing ESP32-C3-SmartHome-Actuator），
可被 A7Z 主控通过 BLE 控制。

> 2026 首届 openvela AI 硬件开发者大赛参赛项目
> **状态：移植完成，已通过硬件实测** ✅

---

## 30 秒了解

| 项 | 值 |
|---|---|
| 芯片 | ESP32-C3（实测 QFN32 rev v0.4，4MB flash） |
| 系统 | openvela（NuttX 分支），自带 `nsh` 命令shell |
| 灯 | 5 颗 WS2812B，数据脚 **GPIO4**，SPI2 MOSI 模拟时序 |
| 控制台 | **USB-Serial-JTAG**（一根 Type-C 即可，无需 USB-TTL） |
| BLE | Peripheral / GATT Server，广播名 `BTSH-LIGHT` |
| 服务 | 自定义 16 位 UUID `0xFF00`（命令 / 状态 / 信息 + 通知） |
| 发现 | 广播内含厂商自定义数据，**不连接即可识别**设备类型与能力 |
| 固件大小 | 429,376 字节 |

**核心能力**：`nsh` 命令台 + 开机自动广播 + 开关灯 + **逐灯 RGB** + 状态通知。
手机 nRF Connect 已实测全通（服务发现、读写、通知、逐灯变色）。

---

## 直接烧录（不用编译）

三条路，任选一条：

### 方式 1：`flash.bat`（Windows 最省事，推荐）

```powershell
cd port
.\flash.bat -Port COM6 -NuttxBin .\nuttx-production.bin
```

### 方式 2：`flash.ps1`

如果 PowerShell 允许运行脚本：

```powershell
cd port
.\flash.ps1 -Port COM6 -NuttxBin .\nuttx-production.bin
```

如果报"**在此系统上禁止运行脚本**"，用这条绕过（不改系统设置）：

```powershell
powershell -ExecutionPolicy Bypass -File .\flash.ps1 -Port COM6 -NuttxBin .\nuttx-production.bin
```

想永久允许脚本（只需一次）：

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

### 方式 3：直接调 esptool（不依赖任何脚本）

```powershell
esptool --chip esp32c3 --port COM6 --baud 921600 write_flash -fs 4MB -fm dio -ff 80m 0x0 nuttx-production.bin
```

---

**关键参数说明**：

- **偏移必须是 `0x0000`** —— 本项目用 `SIMPLE_BOOT` 直接启动，**不需要 Bootloader、不需要分区表**
- 烧录前先关掉占用串口的程序（`serial_log.py` / 串口助手）
- 需要重烧但连不上：**短接 GPIO9 到 GND 再复位**（本板没有 BOOT 键）

烧完打开串口（115200）应看到：

```
NuttShell (NSH)
nsh>
BTSH: boot LED test done
BTSH: GATT service 0xff00 registered (8 attrs)
BTSH: advertising as "BTSH-LIGHT"
BTSH: discovery adv: company=0xffff ver=1 type=1 leds=5 caps=0x07
```

然后手机装 nRF Connect，扫 `BTSH-LIGHT` → 连接 → 读 `0xFF03` 应得 `01 01 00`。

> **遇到显示 `NuttX` 或扫不到厂商数据？** 那是 Windows/安卓的蓝牙缓存。
> 在系统设置里删除该设备、或在 nRF Connect 里 Clear cache 后再扫即可。
> 固件侧的广播字节可用 `port/tools/patch_adv_dump.sh` 验证（见 MEMORY.md 4.6/4.7）。

## 从源码构建

依赖 openvela 源码树（`~/openvela`，WSL2 Ubuntu 22.04 + ext4）。

```bash
# 1. 应用移植改动（幂等，可重复执行）
bash port/apply-all.sh             # 板级移植（16 步）
bash port/apply-stack-fixes.sh     # 三个协议栈修复（4 步）
bash port/apply-discovery-adv.sh   # v1.1 广播能力声明（免连接识别）

# 2. 构建
export PATH=$HOME/openvela/prebuilts/build-tools/linux-x86_64/bin:$HOME/.local/bin:$HOME/tc-bin:$HOME/riscv32-esp-elf/bin:$PATH
export CROSSDEV=riscv64-unknown-elf-
export CONFIG_STACK_USAGE_WARNING=0
cd ~/openvela
./build.sh vendor/espressif/boards/esp32c3/esp32c3-generic/configs/production/ -j20

# 3. 出厂自检（35 项，烧录前必跑）
bash port/tools/check_firmware.sh     # 期望 PASS=35  FAIL=0
```

产物：`~/openvela/nuttx/nuttx.bin`

---

## 仓库结构

```
.
├── README.md                     ← 本文件
├── docs/
│   ├── project-brief-esp32c3-smarthome.md     硬件设计与评审全记录
│   └── openvela-esp32c3-porting-materials.md  移植资料清单
└── port/                         ← 全部交付物
    ├── README.md                 ★ C3 侧完整文档（构建/烧录/自检/排错/实测）
    ├── MEMORY.md                 ★ 完整技术档案（接手先读这个）
    ├── BLE_PROTOCOL_A7Z.md       BLE 协议（A7Z 对接用）
    ├── A7Z_HANDOFF.md            ★ A7Z 开发交接报告
    ├── apply-all.sh              一键重放板级移植（幂等）
    ├── apply-stack-fixes.sh      一键重放协议栈修复（幂等）
    ├── apply-discovery-adv.sh    v1.1 广播能力声明（幂等）
    ├── defconfig-production      实测有效的生产配置
    ├── nuttx-production.bin      ★ 实测可用的固件
    ├── flash.ps1                 Windows 一键烧录
    ├── app-btsh_light/           已修补的 BLE 灯控应用源码
    └── tools/
        ├── ble_client.py         PC 端 BLE 上位机（也是 A7Z 的参考实现）
        ├── ble_probe.py          BLE 连接诊断探针
        ├── serial_log.py         串口日志（断线重连 + 时间戳）
        └── check_firmware.sh     固件出厂自检（35 项）
```

---

## BLE 协议速查

服务 `0xFF00`，全部为 16 位 UUID：

| 特征 | 权限 | 格式 |
|---|---|---|
| `0xFF01` | WRITE | 1 字节 `00`/`01` = 关/开；**4 字节 `[index,R,G,B]` = 逐灯设色**（index `0xFF` = 全部） |
| `0xFF02` | READ + NOTIFY | 1 字节聚合状态：`00` 全灭 / `01` 有灯亮 |
| `0xFF03` | READ | 3 字节，固定 `01 01 00`（协议版本/通道数/保留） |
| `0x2902` | 读写 | CCC，写 `01 00` 开启通知 |

完整时序、坑点、验收清单见 [port/A7Z_HANDOFF.md](port/A7Z_HANDOFF.md)。

---

## 硬件接线

| 功能 | 引脚 | 说明 |
|---|---|---|
| WS2812 数据 | GPIO4 | 经 330Ω 串阻 + SRV05-4 保护 |
| UART0 TX/RX | GPIO21 / GPIO20 | H1 排针 `TXD`/`RXD`（备用控制台） |
| USB D+/D− | GPIO18 / GPIO19 | 烧录 + 控制台都走这里 |
| 复位 | EN（SW2） | |
| 用户键 | SW1 | 注意：**不是 BOOT 键** |

---

## 实测记录（2026-10-22 首次上板）

| 能力 | 结果 |
|---|---|
| 芯片 / Flash 识别 | ✅ ESP32-C3 rev v0.4 / 4MB |
| `nsh>` 控制台 | ✅ |
| 灯带（开机扫色） | ✅ |
| 服务发现 `0xFF00` | ✅ 4 个特征 + CCC 全对 |
| 读 `0xFF03` | ✅ `01 01 00` |
| 开启通知（写 CCC） | ✅ |
| 写 4 字节 RGB | ✅ 第 1 颗灯变红 |
| 状态通知 | ✅ |
| 广播能力声明（v1.1） | 编译通过，待烧录复核 |

**上板才发现的 3 个协议栈 bug**（全部已修，见 [port/README.md](port/README.md) §9）：

1. 控制器→主机流控开启导致 **ACL 数据永远下不来**
2. `bt_att.c` 里 `hdr->code` **悬垂指针** → ATT 请求全部被静默丢弃
3. `gatt_ccc_changed()` **不检查 NULL** → 开通知即整机 PANIC

---

## 已知限制

| 限制 | 影响 |
|---|---|
| `bt_conn` 槽位回收不完整 | 连续连接约 8 次后需复位（已把 `MAX_CONN` 放宽到 8 缓解） |
| USB 控制台只能输出、不能输入 | 不能在 `nsh>` 里敲命令；可用 UART0 + USB-TTL 替代 |
| A7Z 侧尚未开发 | C3 侧已就绪，按协议对接即可 |

---

## 致谢 / 上游

- [openvela](https://github.com/open-vela)（NuttX 分支）
- [esp-hal-3rdparty](https://github.com/espressif/esp-hal-3rdparty)（Espressif HAL + BLE/PHY 预编译库）
- OpenvelaESP-BTSH 项目的 `btsh_light` 应用（本项目在其基础上修复了灯珠写入与 CCC 崩溃）

## License

代码遵循 Apache-2.0（与 openvela / NuttX 一致）。
`docs/` 下的硬件设计文档版权归作者所有。
