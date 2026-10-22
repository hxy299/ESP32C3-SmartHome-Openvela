# 项目记忆 / 完整技术档案

> 这份文件是**给下一个接手的人（或 AI）**的完整记忆。
> 读这一份就能接手，不需要爬聊天记录。
>
> 最后更新：2026-10-22

---

## 0. 项目一句话

把 **openvela（NuttX 分支）移植到 ESP32-C3-WROOM-02-N4**，
做成一块 **5 颗 WS2812B 的 BLE 灯控板**（DogKing ESP32-C3-SmartHome-Actuator），
并让它可以被 A7Z 主控通过 BLE 控制。
**已完成并通过硬件实测。**

---

## 1. 当前状态（最重要）

| 项 | 状态 | 证据 |
|---|---|---|
| openvela 移植到 C3 | ✅ | 编译通过、烧录运行 |
| nsh 控制台 | ✅ | `nsh>` 提示符（USB-Serial-JTAG，一根 Type-C） |
| WS2812 灯带 | ✅ | 开机扫色 + BLE 逐灯 RGB 都能亮 |
| BLE GATT 服务 | ✅ | 手机 nRF Connect 完整发现并读写 |
| 逐灯 RGB | ✅ | 写 `00 40 00 00` → 第 1 颗变红 |
| 通知（Notify） | ✅ | 开启 CCC 后能收到状态变化 |
| 广播能力声明（v1.1） | ✅ | 广播内含厂商数据，中心设备免连接识别 |
| A7Z 对接 | ⏳ | C3 侧已就绪，A7Z 侧待开发（见 `A7Z_HANDOFF.md`） |

**最终固件**：`nuttx-production.bin`，429,376 字节，sha256 `fa6e7eb7da02b4fd…`，出厂自检 35 项全绿。

---

## 2. 硬件事实（实测确认，不是推测）

### 2.1 板子与关键器件

| 项 | 值 |
|---|---|
| 板名 | DogKing ESP32-C3-SmartHome-Actuator（2026 首届 openvela AI 硬件开发者大赛） |
| 模组 | ESP32-C3-WROOM-02-**N4**（4MB flash） |
| 芯片实测 | ESP32-C3 (QFN32) **revision v0.4**，Crystal 40MHz |
| MAC | `dc:da:0c:82:b8:6c`（BLE 地址 = base+2 = `…6E`） |
| Flash 实测 | Manufacturer `0x5e`（Zbit）/ Device `0x4016` / **4MB** |
| 灯珠 | 5 颗 WS2812B（LED3~LED7），菊花链 |
| 电源 | Type-C 5V → AMS1117-3.3 → 3.3V；灯珠 VDD 经 M7 降压 ≈4.2V |

### 2.2 引脚分配（实测可用）

| 功能 | 引脚 | 备注 |
|---|---|---|
| WS2812 数据 | **GPIO4** | 经 R8(330Ω) 串阻 + SRV05-4 保护 |
| UART0 TX | **GPIO21** | → H1 排针 `TXD` |
| UART0 RX | **GPIO20** | → H1 排针 `RXD` |
| USB D+/D− | **GPIO18/19** | 原生 USB-Serial-JTAG，烧录 + 控制台都走它 |
| 复位 | EN（SW2） | |
| **用户按键** | SW1 | ⚠️ **不是 BOOT 键**，与 GPIO9 无关 |

> **注意**：`esp_spibus_initialize()` 会把 SPI2 的 MISO(GPIO2)/CLK(GPIO6)/CS(GPIO10)
> 也配成 SPI 功能。本板这三脚未使用，暂无冲突；若以后要复用需改配置。

### 2.3 烧录方式（实测）

```powershell
esptool --chip esp32c3 --port COM6 --baud 921600 write_flash \
        -fs 4MB -fm dio -ff 80m 0x0 nuttx.bin
```

- **偏移 `0x0000`**（SIMPLE_BOOT 直接启动，不需要 bootloader、不需要分区表）
- 需要重烧时如连不上：**短接 GPIO9 到 GND 再上电/复位**进入下载模式
  （板子上没有 BOOT 键，只能手动短接）
- 烧完 `Hard resetting via RTS pin` 会自动运行

---

## 3. 构建环境（已踩通，照抄即可）

### 3.1 环境组成

| 项 | 位置 / 值 |
|---|---|
| openvela 源码树 | `~/openvela`（WSL2 Ubuntu 22.04，**必须在 ext4 下，不能在 /mnt/d**） |
| 交叉编译器 | `~/riscv32-esp-elf`（esp-13.2.0_20230928）+ `~/tc-bin` 里的 `riscv64-unknown-elf-*` 别名 |
| kconfig | `~/openvela/prebuilts/build-tools/linux-x86_64/bin`（含 `kconfig-conf`） |
| Python kconfig | `prebuilts/tools/python/dist-packages/kconfiglib`（build.sh 自动设 PYTHONPATH） |
| esptool | `pip3 install --user esptool`（WSL）/ Windows 侧 anaconda 也有 |

### 3.2 构建命令

```bash
export PATH=$HOME/openvela/prebuilts/build-tools/linux-x86_64/bin:$HOME/.local/bin:$HOME/tc-bin:$HOME/riscv32-esp-elf/bin:$PATH
export CROSSDEV=riscv64-unknown-elf-
export CONFIG_STACK_USAGE_WARNING=0

# 官方入口（config 变更后必须用这个）
cd ~/openvela
./build.sh vendor/espressif/boards/esp32c3/esp32c3-generic/configs/production/ -j20

# 增量编译（更快，但 config 变更后不要用）
cd ~/openvela/nuttx
make -j20 EXTRAFLAGS="-Wno-cpp -Wno-deprecated-declarations"
```

**产物**：`nuttx/nuttx`（ELF）、`nuttx/nuttx.bin`（烧录镜像）

---

## 4. 全部修复清单（18 条，按性质分类）

### 4.1 环境级（这棵树自带的坑）

| # | 问题 | 修法 |
|---|---|---|
| 1 | `prebuilts/gcc` 里没有 RISC-V 工具链 | 自装 `riscv32-esp-elf` + 建别名 |
| 2 | `prebuilts/tools/.../riscv64-unknown-elf-gcc` 是 ccache 空壳 | 不要用 |
| 3 | `prebuilts/kconfig-frontends` 是空目录 | 用 `build-tools` 里的 kconfig |
| 4 | `CONFIG_RISCV_TOOLCHAIN` 全树未定义 → `CROSSDEV` 落空 → 用主机 gcc | 构建时 `export CROSSDEV=riscv64-unknown-elf-` |
| 5 | **`--help--` typo / `osource` 不支持是误判** | openvela 用的是 **Python kconfiglib**，它**原生支持**。千万不要批量替换 Kconfig！替换会破坏 if/endif 配对（有些 `endif` 在被 `osource` 的文件里） |
| 6 | 直接调 `configure.sh` 会 `ModuleNotFoundError` | 必须用 `build.sh`（它会设置 PYTHONPATH） |
| 7 | `riscv_mtimer.c` 依赖未启用的 `CONFIG_ONESHOT_COUNT` | C3 不用机器定时器，从 `common/Make.defs` 排除 |
| 8 | 工具链**没有 libatomic**（rv32imc 无原子指令） | 自写 `esp_atomic_stubs.c`（单核关中断实现） |
| 9 | `esp-hal` 的 `LOCK_INITIALIZER_UNLOCKED = 0` 对零长数组非法 | 改成 `{}` |
| 10 | `esp_libc_stubs.c` 的 `__assert_func` 不返回 | 末尾加 `for (;;);` |
| 11 | `esp_ble_adapter.c` `%lu` 配 `uint64_t` | 加 `(unsigned long)` 转型 |
| 12 | `esp_wireless.c` 缺 `nuttx/semaphore.h`、`nuttx/irq.h`、`nuttx/spinlock.h` | 补 include（注意 `enter_critical_section` 在 `spinlock.h`，不在 `irq.h`） |

### 4.2 板级 / 应用级

| # | 问题 | 修法 |
|---|---|---|
| 13 | `btsh_light_apply()` 灯珠写入格式错 | 原实现写 8 字节结构体 → 被当成 2 颗灯（第 1 颗青绿、第 2 颗垃圾、第 3~5 颗不动）。改成按驱动格式写 `N × 0x00RRGGBB` |
| 14 | `lederr()` 是内核态宏，应用层不可用 | 改 `syslog(LOG_ERR, …)` |
| 15 | BLE 失败会中断整个 bringup | `esp_bringup` 里记录错误后继续（否则连灯带自检都用不了） |
| 16 | GATT 服务重复注册 | 加 `g_gatt_registered` 守卫 |

### 4.3 **协议栈级（只有上硬件才能发现，最重要）**

| # | Bug | 现象 | 修法 |
|---|---|---|---|
| 17 | **控制器→主机流控开启，主机不归还额度** | 连接成功（`status 0`）但**一个 ACL 字节都收不到**，30 秒后对端超时断开（`reason 19`） | `CONFIG_BLUETOOTH_CNTRL_HOST_FLOW_DISABLE=y` |
| 18 | **`bt_att.c` 的 `hdr->code` 悬垂指针** | 能连上、**服务发现永远失败**（ATT 请求全部被静默丢弃） | `bt_buf_consume()` 前把 opcode 存进局部变量 |
| 19 | **`gatt_ccc_changed()` 调用 `cfg_changed` 不检查 NULL** | 客户端一**开启 NOTIFY（写 CCC）** 就 `Instruction access fault, EPC=00000000` 整机 PANIC | 应用传真实回调 + 协议栈加 NULL 保护 |

> 第 19 条正是原作者在 ESP32-S3 上踩过的同一个坑（他的注释里记着 `write_ccc → rst:0x13`）。


### 4.5 v1.1 新增：广播能力声明

在 ADV_IND 里加了 Manufacturer Specific Data（6 字节）：

```
07 FF | FF FF | 01 | 01 | 05 | 07
        CompanyID ver 类型  灯数 能力位
```

- 目的：中心设备**不连接**即可识别设备类型/能力（对应官方宣传的"无缝发现"）
- 实现：`btsh_light_main.c` 的 `BTSH_DISCOVERY_ADV` 段，`g_adv_data[3]`
- **关键点**：`bt_eir_s.len` = 1(type) + 数据字节数；6 字节数据必须写 `len = 7`。
  写错会导致整条广播失效、设备直接不可见。
- 广播总长 11 字节（上限 31），未超限
- Company ID `0xFFFF` 是 BT SIG 测试保留值，量产必须申请正式 ID

### 4.4 已知遗留问题

| 问题 | 影响 | 建议 |
|---|---|---|
| `bt_conn` 槽位回收不完整（断开后引用计数停在 1） | 连续连接约 8 次后需复位（已把 `MAX_CONN` 放宽到 8 缓解） | 追 `bt_smp_connected`/`bt_att_connected` 的 addref 是否配对 |
| USB 控制台**只能输出、不能输入** | 不能在 `nsh>` 里敲命令 | 修 `esp_usbserial.c` 的 RX 中断；临时用 UART0 + USB-TTL |

---

## 5. 关键配置（实测有效，不要随意改）

```
CONFIG_ARCH_CHIP="esp32c3"
CONFIG_ESPRESSIF_CHIP_SERIES="esp32c3"
CONFIG_ESPRESSIF_SIMPLE_BOOT=y                  # 偏移 0x0，无需 bootloader
CONFIG_ESPRESSIF_BLE=y
CONFIG_WIRELESS_BLUETOOTH_HOST=y
CONFIG_ESPRESSIF_USBSERIAL=y                    # USB 控制台
CONFIG_SYSLOG_CONSOLE=y                         # ★ 没开这个就看不到任何日志
CONFIG_BLUETOOTH_CNTRL_HOST_FLOW_DISABLE=y      # ★ 关流控，否则 ACL 收不到
CONFIG_BLUETOOTH_MAX_CONN=8                     # ★ 缓解槽位泄漏
CONFIG_BLUETOOTH_MAX_PAIRED=1                   # CCC 数组长度，必须 >=1
CONFIG_ESP32C3_GENERIC_BTSH_AUTOSTART=y         # 开机自动广播
CONFIG_ESP32C3_GENERIC_WS2812=y
CONFIG_ESP32C3_GENERIC_WS2812_NLEDS=5
CONFIG_WS2812=y
CONFIG_WS2812_LED_COUNT=5                       # 三处灯数必须一致
CONFIG_BTSH_LIGHT=y
CONFIG_BTSH_LIGHT_LED_COUNT=5
CONFIG_ESPRESSIF_SPI2=y
CONFIG_ESPRESSIF_SPI2_MOSIPIN=4                 # WS2812 数据脚
CONFIG_WS2812_FREQUENCY=8000000                 # 5.9–9MHz 档，T0H≈250ns/T1H≈625ns
CONFIG_SCHED_LPWORK=y                           # 工作队列
```

### WS2812 时序核算（实测有效）

| 项 | 值 | 规格 |
|---|---|---|
| T0H | 250 ns | 200–500 ns ✅ |
| T1H | 625 ns | 550–850 ns ✅ |
| 复位低电平 | 60 µs | >50 µs ✅ |

---

## 6. 启动链路（排查启动问题必看）

```
ROM（flash 0x0）
 └─ entry 0x40389642（IRAM）
     └─ __esp_start
         ├─ bootloader_init() → bootloader_clear_bss_section()   ← bss 在这里清零
         ├─ map_rom_segments(PRIMARY_SLOT_OFFSET=0 + LMA)         ← flash 映射
         └─ nx_start
             └─ nsh_main
                 └─ nsh_initialize → boardctl(BOARDIOC_INIT)
                     └─ board_app_initialize → esp_bringup()
                         ├─ esp_ble_initialize → bt_netdev_register → bt_initialize
                         ├─ board_ws2812_initialize → /dev/leds0
                         └─ (production) autostart 任务 → LED 扫色 + 广播
```

**关键点**：`CONFIG_BOARD_LATE_INITIALIZE` 没开，所以 `esp_bringup()` 是**在 nsh 启动时**经 `boardctl` 调用的。看到 `nsh>` 时 BLE 和灯带都已初始化完。

---

## 7. 调试方法与工具

### 7.1 常用工具（都在 `port/tools/`）

| 工具 | 用途 |
|---|---|
| `serial_log.py` | **串口日志（断线自动重连 + 时间戳）**。⚠️ 绝对不能碰 DTR/RTS——C3 会把它当复位信号 |
| `ble_client.py` | PC 端 BLE 上位机 + A7Z 参考实现。`--scan/--on/--off/--rgb/--rainbow/--selftest` |
| `ble_probe.py` | BLE 连接诊断探针（区分"连上就断"和"连上不回包"） |
| `check_firmware.sh` | 固件出厂自检 35 项（烧录前跑） |

### 7.2 调试 BLE 的标准流程

```bash
# 1. 抓串口日志（另一个窗口开着不动）
python tools/serial_log.py -p COM6 -b 115200

# 2. 跑连接测试
python tools/ble_probe.py
```

**判据**：

| 日志 | 含义 |
|---|---|
| `le_conn_complete: status 0 ... role 1` | 链路层连接成功 |
| `bt_receive: ... type 3` | ACL 数据到达（没有 = 流控问题） |
| `bt_l2cap_receive: Packet for CID 4` | ATT 请求到达 |
| `BTSH: central connected` | 主机层知道连接建立 |
| `BTSH_ATT_PROBE: code 0x02` | ATT 处理函数被调用 |
| `hci_disconn_complete: ... reason N` | 断开原因码 |

### 7.3 排查"整机 PANIC"的方法

1. 看 `EPC`：`EPC=00000000` → **空函数指针**（本次就是这个）
2. 用 `riscv64-unknown-elf-addr2line -f -e nuttx 0x<PC>` 反查函数
3. 看 panic 时的 `task:` 名字（`lpwork` / `BT_HCI_Tx` 等能提示上下文）

---

## 8. 交付物清单

```
port/
├── README.md                    C3 侧完整文档（构建/烧录/自检/排错/实测记录）
├── BLE_PROTOCOL_A7Z.md          BLE 协议（A7Z 对接用）
├── A7Z_HANDOFF.md               ★ A7Z 开发交接报告
├── MEMORY.md                    ★ 本文件（完整记忆）
├── apply-all.sh                 一键重放板级移植（16 步，幂等）
├── apply-stack-fixes.sh         ★ 一键重放 3 个协议栈修复（幂等）
├── defconfig-production         ★ 实测有效的生产配置
├── defconfig-btlight            默认（手动 start）
├── defconfig-btlight-auto       开机自动广播
├── esp32c3_ws2812.c             板级 WS2812 初始化
├── esp_atomic_stubs.c           rv32imc 的 __atomic_* 实现
├── app-btsh_light/              已修补的 BLE 灯控应用最终版
├── flash.ps1                    Windows 一键烧录
├── nuttx-production.bin         ★ 实测可用的固件
├── nuttx.bin                    默认固件（UART 控制台）
└── tools/
    ├── ble_client.py            PC 端 BLE 工具 + A7Z 参考实现
    ├── ble_probe.py             BLE 连接诊断探针
    ├── serial_log.py            串口日志（自动重连）
    └── check_firmware.sh        固件出厂自检（35 项）
```

---

## 9. 从头复现的完整步骤

```bash
# 0. 前提：openvela 源码树在 ~/openvela（ext4），WSL2 Ubuntu 22.04
#    已装 riscv32-esp-elf、CROSSDEV 别名、kconfig 在 PATH

# 1. 应用移植改动
bash port/apply-all.sh            # 板级移植（16 步）
bash port/apply-stack-fixes.sh    # 协议栈修复（4 步）

# 2. 构建
cd ~/openvela
./build.sh vendor/espressif/boards/esp32c3/esp32c3-generic/configs/production/ -j20

# 3. 自检
bash port/tools/check_firmware.sh   # 期望 PASS=35 FAIL=0

# 4. 烧录
esptool --chip esp32c3 --port COM6 --baud 921600 write_flash \
        -fs 4MB -fm dio -ff 80m 0x0 nuttx/nuttx.bin

# 5. 验证
python port/tools/serial_log.py -p COM6 -b 115200   # 看 nsh> 和各条 BTSH 日志
python port/tools/ble_client.py --selftest          # PC 端全链路自检
```

**验证成功的标志**：

```
串口:
  NuttShell (NSH)
  nsh>
  BTSH: boot LED test done
  BTSH: GATT service 0xff00 registered (8 attrs)
  BTSH: advertising as "BTSH-LIGHT"

手机/PC:
  扫到 BTSH-LIGHT → 连上 → 读 0xFF03 = 01 01 00 → 写 0xFF01 灯变色
```

---

## 10. 最重要的经验教训（避免重复踩坑）

1. **不要相信"能编译就能跑"。** 本项目有 **3 个致命 bug 只在硬件上暴露**，静态检查全部漏过。
2. **尽早把控制台搞通。** 前两轮因为没开 `CONFIG_SYSLOG_CONSOLE` 和协议栈日志，只能靠猜；打开日志后 5 分钟定位。
3. **`EPC=00000000` 一律怀疑空函数指针**，`addr2line` 反查最快。
4. **"能连上"和"能用"是两件事**：广播/连接是控制器的活，ACL/ATT 才是主机的活，要逐层验证。
5. **别动 ESP32-C3 的 DTR/RTS**，它把这当成复位信号。
6. **别批量替换 Kconfig 的 `osource`/`--help--`**，openvela 用的 kconfiglib 原生支持。
7. **`build.sh` 会用 unionfs 覆盖层**，手工补丁可能被冲掉；增量编译用 `make` 更稳。
8. **灯珠数量有三处配置**（`WS2812_LED_COUNT` / `ESP32C3_GENERIC_WS2812_NLEDS` / `BTSH_LIGHT_LED_COUNT`），必须一致——自检脚本会查。

---

## 11. 联系人 / 归属

- 硬件与项目：DogKing（hxy299），2026 首届 openvela AI 硬件开发者大赛
- 仓库：https://github.com/hxy299/ESP32C3-SmartHome-Openvela
- 上游：openvela（NuttX fork）、esp-hal-3rdparty、OpenvelaESP-BTSH
