# openvela 移植到 ESP32-C3-WROOM-02-N4

> 板子：**DogKing ESP32-C3-SmartHome-Actuator**（2026 首届 openvela AI 硬件开发者大赛）
> 目标：跑通 nsh 串口控制台 + BLE GATT 灯控服务，可与 A7Z 开发板通信

---

## 1. 交付内容

```
port/
├── apply-all.sh              ★ 一键重放全部移植改动（幂等，推荐入口）
├── defconfig-btlight         默认配置（手动 start）
├── defconfig-btlight-auto    开机自动广播变体
├── esp32c3_ws2812.c          板级 WS2812 初始化（SPI2 MOSI 模拟时序）
├── esp_atomic_stubs.c        rv32imc 缺 libatomic 的 __atomic_* 实现（单核关中断）
├── app-btsh_light/           ★ 已修补的 BLE 灯控应用最终版（含 test 自检命令）
├── flash.ps1                 ★ Windows 一键烧录（SIMPLE_BOOT，单文件烧到 0x0）
├── nuttx.bin                 ★ 已编译好的固件（429,224 字节）
├── nuttx.hex                 同上，Intel HEX 格式
├── tools/
│   ├── ble_client.py         ★ PC 端 BLE 测试工具 + A7Z 侧实现参考
│   └── check_firmware.sh     ★ 固件出厂自检（34 项，烧录前跑）
├── BLE_PROTOCOL_A7Z.md       A7Z 侧对接用的 BLE 协议文档
└── README.md                 本文
```

安装后会在 openvela 树里新增/修改：

| 文件 | 动作 |
|---|---|
| `nuttx/boards/risc-v/esp32c3/esp32c3-generic/src/esp32c3_ws2812.c` | 新增 |
| `nuttx/boards/risc-v/esp32c3/esp32c3-generic/configs/btlight/defconfig` | 新增 |
| `vendor/espressif/boards/esp32c3/esp32c3-generic/configs/btlight/defconfig` | 新增（官方 vendor 布局） |
| `vendor/espressif/boards/esp32c3/esp32c3-generic/scripts/Make.defs` | 新增（build.sh 需要） |
| `nuttx/arch/risc-v/src/esp32c3/esp_atomic_stubs.c` | 新增 |
| `nuttx/boards/risc-v/esp32c3/esp32c3-generic/src/Make.defs` | 追加编译规则 |
| `nuttx/arch/risc-v/src/esp32c3/Make.defs` | 追加 atomic stub |
| `nuttx/boards/risc-v/esp32c3/esp32c3-generic/Kconfig` | 追加 `ESP32C3_GENERIC_WS2812` |
| `nuttx/boards/risc-v/esp32c3/esp32c3-generic/src/esp32c3_bringup.c` | 追加初始化调用 |
| `nuttx/boards/risc-v/esp32c3/esp32c3-generic/src/esp32c3-generic.h` | 追加函数声明 |
| `nuttx/arch/risc-v/src/common/Make.defs` | C3 排除 `riscv_mtimer.c` |
| `apps/wireless/bluetooth/btsh_light/btsh_light_main.c` | 补广播 API 声明、去掉未用 CCC 变量 |

BLE 服务本身**不需要新写代码** —— 直接用 openvela 自带的
`apps/wireless/bluetooth/btsh_light`（由 OpenvelaESP-BTSH 项目提供）。


---

## 2. 硬件对应关系

| 功能 | 引脚 | 说明 |
|---|---|---|
| 串口控制台 UART0 | **GPIO20 (RX) / GPIO21 (TX)** | 板上 H1 三针排针：`1=TXD 2=RXD 3=GND` |
| WS2812B 数据 | **GPIO4** | SPI2 MOSI 模拟时序，串 330Ω，接第一颗 LED3 的 DIN |
| USB | GPIO18 (D−) / GPIO19 (D+) | Type-C，备用烧录/调试 |
| 下载键 | GPIO9 (SW1) | 按住进下载模式 |
| 复位键 | EN (SW2) | — |
| 灯带供电 | 5V 经 M7 降压到约 4.2V | 逻辑电平匹配 |

> 串口适配器必须是 **3.3V 电平**，接 H1 的 TX/RX/GND，波特率 **115200**。

---

## 3. 环境准备

官方文档声明 openvela 不支持在 WSL 编译，但 **WSL2 + ext4 实测可用**，关键是把源码放在 WSL 内部（`~/openvela`），不要放 `/mnt/d`。

### 3.1 必备组件

```bash
# 已确认 Ubuntu 22.04 自带：git make gcc g++ python3 bison flex gperf cmake repo
# 缺的只有 kconfig-frontends，按下面编译
cd ~/openvela/prebuilts/kconfig-frontends
./configure --prefix=$PWD --enable-mconf --disable-nconf --disable-gconf \
            --disable-qconf --disable-shared --enable-static
touch aclocal.m4 Makefile.in
make install
export PATH=$PWD/bin:$PATH
```

### 3.2 RISC-V 工具链

openvela 的 `prebuilts/gcc` 里**只有 Xtensa（ESP32-S3 用）没有 RISC-V**，需要自己装。

```bash
cd ~ && mkdir -p tc_dl && cd tc_dl
curl -LO https://github.com/espressif/crosstool-NG/releases/download/esp-13.2.0_20230928/riscv32-esp-elf-13.2.0_20230928-x86_64-linux-gnu.tar.xz
tar -xf riscv32-esp-elf-13.2.0_20230928-x86_64-linux-gnu.tar.xz -C ~

# NuttX 默认用 riscv64-unknown-elf- 前缀，建一组别名指向 esp 工具链
mkdir -p ~/tc-bin && cd ~/tc-bin
for f in ~/riscv32-esp-elf/bin/riscv32-esp-elf-*; do
  n=$(basename "$f"); ln -sf "$f" "${n/riscv32-esp-elf-/riscv64-unknown-elf-}"
done

export PATH=~/tc-bin:~/riscv32-esp-elf/bin:$PATH
riscv64-unknown-elf-gcc --version   # 应输出 13.2.0
```

> 为什么不用最新的 gcc 16.1：太新容易触发 NuttX 的 `-Werror`。13.2.0 是 NuttX esp32c3 验证过的版本。
> 为什么不用 `prebuilts/tools/.../riscv64-unknown-elf-gcc`：那是个 **ccache 空壳**，不是编译器。

---

## 4. 构建

```bash
cd ~/openvela

# 1) 安装板级移植
bash /mnt/d/.../port/install.sh

# 2) 配置（注意：源码树若之前配过别的板子，先 distclean）
cd nuttx
make distclean
./tools/configure.sh esp32c3-generic:btlight

# 3) 解析依赖（必须，否则 CONFIG_ESPRESSIF_CHIP_SERIES 为空会导致找不到 hal_esp32c3.mk）
export PATH=~/openvela/prebuilts/kconfig-frontends/bin:~/tc-bin:~/riscv32-esp-elf/bin:$PATH
make olddefconfig
grep CHIP_SERIES .config        # 应显示 "esp32c3"

# 4) 编译
make -j$(nproc)
```

产物：`nuttx/nuttx`（ELF）、`nuttx/nuttx.bin`（可直接烧）。

首次编译会自动 `git clone esp-hal-3rdparty`（含 BLE 控制器预编译库），需要能访问 GitHub，耗时几分钟。

### 关键配置自检

```bash
grep -E 'ESPRESSIF_CHIP_SERIES|ESP32C3_GENERIC_WS2812|WS2812_FREQUENCY|SPI2_MOSIPIN|BTSH_LIGHT|ESPRESSIF_BLE' .config
```

期望：

```
CONFIG_ESPRESSIF_CHIP_SERIES="esp32c3"
CONFIG_ESPRESSIF_BLE=y
CONFIG_BTSH_LIGHT=y
CONFIG_ESP32C3_GENERIC_WS2812=y
CONFIG_ESP32C3_GENERIC_WS2812_NLEDS=5
CONFIG_ESPRESSIF_SPI2_MOSIPIN=4
CONFIG_WS2812_FREQUENCY=8000000
```

---

## 4b. 烧录前自检（强烈建议每次编译后跑一遍）

```bash
bash port/tools/check_firmware.sh
```

不改任何东西，纯静态检查 ELF + `.config` + 二进制内容，共 **34 项**，
分 9 组：

| 组 | 检查内容 |
|---|---|
| 1 | 产物存在（ELF / bin / .config） |
| 2 | 目标架构（RISC-V / esp32c3 / RV32） |
| 3 | **镜像布局**：入口点在 IRAM、SIMPLE_BOOT、MMU 约束（`VMA%64K == LMA%64K`）、镜像长度覆盖全部 flash 内容 |
| 4 | 核心符号（nsh / GATT / WS2812 / BLE） |
| 5 | 功能要素字符串（广播名 / 自检 / RGB / 断开重播） |
| 6 | **灯珠配置三处一致** + WS2812 频率档位 + 数据脚 GPIO4 |
| 7 | 串口控制台：UART0 / 115200 / TX=GPIO21 / RX=GPIO20 / `INIT_ENTRYPOINT=nsh_main` / `NSH_ARCHINIT` / `BOARDCTL` |
| 8 | BLE：控制器 / host / `btsh_light` / `MAX_PAIRED>=1`（CCC 非零长）/ `LPWORK`（断开重播需要） |
| 9 | **启动路径**：`bootloader_init()` 是否清 bss、bss 范围是否合法、XIP 段 LMA 是否 64KB 对齐 |

正常输出结尾：

```
结果: PASS=34  FAIL=0  SKIP=0
全部通过，可以烧录：port/flash.ps1 -Port COMx -Erase
```

### 这个检查本身也验证过（不是走过场）

故意制造三种配置退化，确认都能被抓到：

| 人为改动 | 结果 |
|---|---|
| `ESP32C3_GENERIC_WS2812_NLEDS` 5 → 3 | `FAIL 灯珠数量不一致: 5 / 3 / 5` |
| `WS2812_FREQUENCY` 8000000 → 1000000 | `FAIL WS2812 频率 1000000 不在驱动支持范围` |
| `ESPRESSIF_UART0_TXPIN` 21 → 5 | `FAIL UART0 引脚 TX=5 RX=20，与板子 H1(GPIO20/21) 不符` |

恢复后重新全绿（34/0/0）。

用处：以后改了 defconfig、换了灯珠数量、调了引脚，**不用等上板才发现**。

---

## 5. 烧录

### 5.1 本板用的是 SIMPLE_BOOT（直接启动）—— 只烧一个文件

> ⚠️ 通用 NuttX 文档说的是"烧 bootloader@0x0 + 分区表@0x8000 + 应用@0x10000"，
> **那是 `make flash ESPTOOL_BINDIR=...` 的 IDF-bootloader 方案，不适用于本配置。**

openvela 的 ESP32-C3 配置默认启用 `CONFIG_ESPRESSIF_SIMPLE_BOOT=y`
（`arch/risc-v/src/common/espressif/Kconfig`，`default y`），
对应 `tools/espressif/Config.mk`：

```make
else ifeq ($(CONFIG_ESPRESSIF_SIMPLE_BOOT),y)
    APP_OFFSET     := 0x0000
    APP_IMAGE      := nuttx.bin
```

即：**只需要把 `nuttx.bin` 烧到 `0x0000`**，不需要二级 bootloader、不需要分区表。
（ELF 转镜像时用了 `--ram-only-header`，正是直接启动格式。）

当前 flash 参数：**4MB / DIO / 80MHz**（`.config` 的 `ESPRESSIF_FLASH_*`）。

### 5.2 Windows 一键烧录（推荐）

WSL 里转发 USB 串口很麻烦，直接在 Windows 侧烧最省事：

```powershell
cd port
.\flash.ps1 -Port COM5              # 烧 nuttx.bin 到 0x0
.\flash.ps1 -Port COM5 -Erase       # 先整片擦除（首次或状态异常时）
.\flash.ps1 -Port COM5 -Baud 115200 # 烧录不稳时降速
```

需要 `pip install esptool`。

### 5.3 手工命令（等价）

```
esptool --chip esp32c3 --port COM5 --baud 921600 write_flash ^
        -fs 4MB -fm dio -ff 80m 0x0 nuttx.bin
```

### 5.4 WSL 内烧录（可选，需 usbipd-win 转发串口）

```bash
cd ~/openvela/nuttx
export PATH=$HOME/.local/bin:$HOME/tc-bin:$HOME/riscv32-esp-elf/bin:$PATH
make flash ESPTOOL_PORT=/dev/ttyUSB0
```

### 5.5 进下载模式

正常情况下 esptool 会自动复位进下载模式。若报 "Failed to connect"：

**按住 SW1(BOOT/IO9) → 点一下 SW2(EN) 松开 → 再松开 SW1**


---

## 6. 验证步骤

### 6.1 串口控制台

**方式 A（推荐，一根 Type-C 即可）**：控制台走 **USB-Serial-JTAG**，
插上 Type-C 就会出现一个 COM 口，115200 8N1：

```bash
python tools/console.py -p COM6          # 交互式：直接在 nsh> 里敲命令
python tools/serial_cmd.py -p COM6 -c "help"   # 只发一条命令并打印回应
python tools/serial_log.py -p COM6       # 只抓日志（只读，不转发键盘）
```

> ❗`serial_log.py` 是**只读**的（为保证绝不触发复位，它不向串口写任何字节），
> 所以在那个窗口敲键盘没反应是正常的 —— 敲命令请用 `console.py`。

实测可用的 nsh 命令：

```
nsh> help
nsh> btsh_light state      ← 打印服务 UUID / LED 设备 / 当前状态
nsh> btsh_light test       ← 灯带自检
nsh> ps                    ← 看内核线程
```

**方式 B（备用）**：用 **3.3V** USB-TTL 接 H1（**不要接 5V**），115200 8N1：

| H1 排针 | 模组引脚 | 接到 USB-TTL |
|---|---|---|
| TXD | **GPIO21**（UART0 TX） | → 适配器 **RX** |
| RXD | **GPIO20**（UART0 RX） | ← 适配器 **TX** |
| GND | GND | ↔ 适配器 **GND**（必须共地） |

```

NuttShell (NSH) NuttX-...
nsh>
```

看到 `nsh>` 说明**移植成功**。

### 6.2 灯带自检（先做这一步，不依赖 BLE）

```
nsh> btsh_light state
nsh> btsh_light test
```

- `state` 里的 **`fd=3`（不为 −1）** 表示 `/dev/leds0` 打开成功，即 WS2812 驱动已注册。
- `test` 会让 **5 颗灯依次亮 红 → 绿 → 蓝 → 白**（各 400ms），然后熄灭并恢复逻辑状态。

这样能把故障**分层定位**：

| 现象 | 说明 |
|---|---|
| `fd=-1` | `/dev/leds0` 没注册 → WS2812 驱动/SPI 初始化失败（看开机的 `WS2812: /dev/leds0 registered` 日志） |
| `fd=3` 但灯不亮 | SPI 时序或硬件问题 → 查 GPIO4 焊接、330R、灯珠方向、VDD≈4.2V |
| 只有第 1~2 颗变色 | 就是之前那个"写 8 字节结构体"的 bug（已修） |
| 5 颗全对 | SPI + WS2812 链路 OK，可以进入 BLE 测试 |

### 6.3 BLE 广播

```
nsh> btsh_light start
nsh> btsh_light stop
```

`start` 后手机/PC 应能扫到 `BTSH-LIGHT`。

**断开后会自动重新广播**（已实现），串口会打印：

```
BTSH: central connected
BTSH: central disconnected
BTSH: re-advertising after disconnect
```

所以可以反复连接/断开，不需要 `stop`+`start`。

### 6.3b 逐灯 RGB（5 颗灯独立控制）

`0xFF01` 支持两种写入格式，**按长度自动区分**，老协议不受影响：

| 写入 | 含义 |
|---|---|
| 1 字节 `00`/`01` | 全灭 / 全部绿色（旧协议不变） |
| 4 字节 `[index,R,G,B]` | `index` 0..4 = 第几颗；**`0xFF` = 全部** |

PC 端验证：

```bash
python port/tools/ble_client.py --rainbow        # 每颗一个颜色
python port/tools/ble_client.py --rgb 0 64 0 0   # 只改第 1 颗为红
python port/tools/ble_client.py --rgb 255 0 0 64 # 全部蓝色
```

`--rainbow` 是最有用的验收手段：5 颗灯颜色/顺序错一眼就能看出来，
也能顺带确认 WS2812 数据线方向（DIN 从哪颗进）。

状态特征 `0xFF02` 仍是 1 字节**聚合**语义：任意一颗非全黑 → `0x01`，全黑 → `0x00`。

### 6.4 A7Z 联调

按 [BLE_PROTOCOL_A7Z.md](BLE_PROTOCOL_A7Z.md)：A7Z 扫描 `BTSH-LIGHT` → 连接 →
读 `0xFF03` 得到 `01 01 00` → 写 `0xFF01 = 0x01` 开灯 → 读 `0xFF02` 得到 `01`。

### 6.5 PC 端验证（推荐，不用等 A7Z / 不用手机）

仓库自带一个 bleak 写的小工具，同时也是 **A7Z 侧实现参考**：

```bash
pip install bleak
python port/tools/ble_client.py --scan        # 扫到 BTSH-LIGHT
python port/tools/ble_client.py --info        # 应得 01 01 00
python port/tools/ble_client.py --selftest    # 完整自检：info→订阅→开→关→校验
python port/tools/ble_client.py --watch 30    # 订阅通知，实时看状态变化
```

`--selftest` 全绿就说明：广播 → 连接 → GATT 发现 → 读写 → 通知 全链路通。

**重连测试（验证断开重播）**：

```bash
python port/tools/ble_client.py --info       # 第一次连接，退出（触发断开）
python port/tools/ble_client.py --info       # 应能再次扫到并连上
```

第二次还能扫到 `BTSH-LIGHT`，就说明重播生效。如果不修这个缺陷，第二次必定扫不到。

### 6.5 手机 App 快速验证（备选）

nRF Connect 扫 `BTSH-LIGHT`，直接读写这三个特征。

### 6.6 A7Z 联调

按 [BLE_PROTOCOL_A7Z.md](BLE_PROTOCOL_A7Z.md)：A7Z 扫描 `BTSH-LIGHT` → 连接 →
读 `0xFF03` 得到 `01 01 00` → 写 `0xFF01 = 0x01` 开灯 → 读 `0xFF02` 得到 `01`。

A7Z 侧代码可直接对照 `port/tools/ble_client.py` 改写 —— 协议时序、UUID、字节格式、
通知订阅顺序都在里面。

---

## 7. 排错

| 症状 | 排查方向 |
|---|---|
| `chip/hal_.mk: No such file` | `make olddefconfig` 没跑成功 → `CONFIG_ESPRESSIF_CHIP_SERIES` 为空。检查 kconfig-frontends 是否装好 |
| `kconfig-conf: command not found` | kconfig-frontends 没编译，见 3.1 |
| `riscv64-unknown-elf-gcc: command not found` | 工具链 PATH 没设，见 3.2 |
| 上电无串口输出 | 检查 H1 接线/波特率（115200）；确认烧到 `0x0`；按 SW2 复位 |
| `btsh_light state` 里 `fd=-1` | WS2812 驱动没注册：查 `CONFIG_WS2812`、`CONFIG_ESPRESSIF_SPI2`、`MOSIPIN=4` |
| 灯不亮但 fd 正常 | `CONFIG_WS2812_FREQUENCY` 必须落在 5.9–9MHz（用 8000000）；用 RMT 方案则需另配 |
| 扫不到 BTSH-LIGHT | 没执行 `btsh_light start`；或 BLE 控制器初始化失败（看启动日志） |

---

## 8. 当前状态

| 项 | 状态 |
|---|---|
| 板级移植代码 | ✅ 已装入源码树 |
| 构建配置 | ✅ `esp32c3-generic:btlight`（2910 行完整 .config） |
| BLE GATT 灯控服务 | ✅ 复用 openvela 自带 `btsh_light` |
| A7Z 对接协议文档 | ✅ 已输出 |
| **完整编译通过** | ✅ **已验证**，产出 `nuttx.bin` |
| 运行期实测（nsh / BLE） | ❌ 板子未到货（U1 模组与 C15 待补） |
| RGB 彩色控制 | ⏳ 当前协议是单路开关，扩展方案见协议文档第 7 节 |

### 8.1 编译验证结果（实测）

```
$ make clean && make -j20
  MAKE_RC=0，error 行数 = 0，耗时 12.8s（20 核）

$ ls -l nuttx nuttx.bin
-rwxr-xr-x  640340  nuttx        # ELF 32-bit LSB executable, UCB RISC-V, RVC, soft-float ABI
-rw-r--r--  429224  nuttx.bin    # ESP32-C3 image（"Successfully created ESP32-C3 image"）
                               # sha256 c053b6128ff8c847…（含编译时间戳，重编会变，大小不变）

$ riscv64-unknown-elf-size nuttx
   text	   data	    bss	    dec	    hex
 367990	   5380	 390622	 763992	  ba858

链接内存报告:
  ROM:            428656 B / 4 MB      (10.22%)
  iram0_0_seg:     39392 B / 321296 B  (12.26%)
  irom0_0_seg:    293186 B / 4 MB      ( 6.99%)
  dram0_0_seg:     68304 B / 321296 B  (21.26%)
  drom0_0_seg:    363096 B / 4 MB      ( 8.66%)
  rtc_iram_seg:       40 B / 8168 B    ( 0.49%)
```

关键符号已确认进入镜像（`riscv64-unknown-elf-nm`）：

```
nsh_main, nsh_consolemain                      串口控制台
bt_start_advertising, bt_stop_advertising      BLE 广播
bt_gatt_register                               GATT 服务注册
btsh_light_main, btsh_light_apply              BLE 灯控应用
ws2812_leds_register, board_ws2812_initialize  WS2812 驱动
esp_ble_initialize, esp_bringup                BLE 控制器初始化
btsak_cmd_advertise / gatt / connect / discover  调试命令
__atomic_fetch_add_4                           单核原子操作补充
```

### 8.1b WS2812 时序与 SPI 配置核算（静态验证）

| 项 | 值 | 依据 |
|---|---|---|
| SPI 频率 | 8 MHz | `CONFIG_WS2812_FREQUENCY=8000000`（驱动支持 3.6–5.0 / 5.9–9.0 MHz 两档） |
| T0H | 250 ns | 2 个 SPI 位 × 125 ns；WS2812 规格 200–500 ns ✅ |
| T1H | 625 ns | 5 个 SPI 位 × 125 ns；WS2812 规格 550–850 ns ✅ |
| 复位低电平 | 60 µs | `WS2812_RST_CYCLES` = 60 字节 = 480 位；规格 >50 µs ✅ |
| SPI 模式 | MODE3, 8 bit | 驱动自己设置（`ws2812.c` 383–386 行） |
| MOSI 引脚 | GPIO4 | `CONFIG_ESPRESSIF_SPI2_MOSIPIN=4`，走 GPIO matrix（C3 的 IOMUX MOSI 只在 GPIO7） |
| 总线枚举 | `ESPRESSIF_SPI2 == 2` | `esp_spibus_initialize(2)` 命中 `switch` 的 `case ESPRESSIF_SPI2` ✅ |

注意：`esp_spibus_initialize()` 也会把 SPI2 的 **MISO(默认 GPIO2) / CLK(默认 GPIO6) / CS(默认 GPIO10)**
配成 SPI 功能。本板这三脚未使用，无冲突；若后续复用这些 GPIO 需记得关掉或改引脚。

### 8.1c 板级初始化到底什么时候跑（看启动日志要知道这点）

`CONFIG_BOARD_LATE_INITIALIZE` **未开**，所以 `esp_bringup()` 不是在内核启动阶段调用，
而是在 **NSH 启动时**：

```
nsh_main
 └─ nsh_initialize()                    apps/nshlib/nsh_init.c
     └─ boardctl(BOARDIOC_INIT, 0)      #ifdef CONFIG_NSH_ARCHINIT
         └─ board_app_initialize()      boards/.../esp32c3_appinit.c
             └─ esp_bringup()           # 未开 BOARD_LATE_INITIALIZE 时走这里
                 ├─ esp_ble_initialize()      → BLE 控制器 + 协议栈
                 ├─ board_ws2812_initialize() → /dev/leds0
                 └─ (btlight-auto) 自动广播任务
```

**实际影响**：

- `nsh>` 提示符出现时，BLE 和灯带**已经初始化完了**（串口里能看到对应日志）。
- BLE 初始化耗时会让提示符晚一点出现——这是正常的，不是卡死。
- 相关配置：`CONFIG_NSH_ARCHINIT=y`、`CONFIG_BOARDCTL=y`（都已确认）。

### 8.1d 内存余量（BLE 能不能跑得开）

链接报告：

```
dram0_0_seg:   68,360 B / 321,296 B   (21.28%)   → 约 250 KB 余量
iram0_0_seg:   39,392 B / 321,296 B   (12.26%)
irom0_0_seg:  293,914 B / 4 MB        ( 7.01%)
drom0_0_seg:  363,680 B / 4 MB        ( 8.67%)
```

堆从 `g_idle_topstack` 起算到 ROM 保留区（`esp_allocateheap.c`），余量充足。
ESP32-C3 的 BLE 协议栈大约需要几十 KB，不存在内存瓶颈。

### 8.1e 启动路径验证（机器码级）

上电后能不能跑起来，取决于两件很容易被忽略的事。两件都已验证到指令级。

#### ① `.bss` 谁来清零

`.bss` 是 NOBITS，**不在镜像里**，ROM 只加载 data 段。如果没人清零，所有全局变量初值都是垃圾。

`esp_start.c` 里是这么写的：

```c
#ifdef CONFIG_ESPRESSIF_SIMPLE_BOOT
  if (bootloader_init() != 0) { ... }     // ← 我们走这条
#else
  bootloader_clear_bss_section();          // ← 这条不会执行
#endif
```

清 bss 的动作藏在 `bootloader_init()` 内部（`bootloader_esp32c3.c`，`#if !CONFIG_APP_BUILD_TYPE_RAM`）。
在**实际固件里**反汇编确认：

```
40388cfe:  jal  40388b8a <bootloader_clear_bss_section>     ← 确实调用了
...
40388b8e:  add a2, gp, -878    # 3fc8aef0   ← _bss_start
40388b92:  add a5, a5, -1272   # 3fc90b08   ← _bss_end
40388b9a:  li  a1, 0           # 填充值 0
40388ba4:  jr  ... memset
```

即 `memset(0x3fc8aef0, 0, 0x2C18)` —— 正好是 `.dram0.bss` 的 23,576 字节。✅

#### ② 烧录偏移为什么是 0x0（源码级证据）

`esp_start.c` 用 `PRIMARY_SLOT_OFFSET + LMA` 决定 flash 映射位置：

```c
#ifdef CONFIG_ESPRESSIF_BOOTLOADER_MCUBOOT
#  define PRIMARY_SLOT_OFFSET   CONFIG_ESPRESSIF_OTA_PRIMARY_SLOT_OFFSET   // 0x10000
#else
/* Force offset to the beginning of the whole image */
#  define PRIMARY_SLOT_OFFSET   0                                          // ← SIMPLE_BOOT
#endif
```

我们的配置是 SIMPLE_BOOT（非 MCUBOOT），所以 `PRIMARY_SLOT_OFFSET = 0`：

| 项 | 值 |
|---|---|
| `_image_irom_lma` | `0x00010000` → 映射到 VMA `0x42000000` |
| `_image_drom_lma` | `0x00060000` → 映射到 VMA `0x3c050000` |
| `PRIMARY_SLOT_OFFSET` | `0` |
| 结论 | 镜像里有内容的 flash 段落在 `0x10000` / `0x60000` → **整包烧到 `0x0`** |

这也和 `tools/espressif/Config.mk` 的 `APP_OFFSET := 0x0000` 一致。
**若哪天改成 MCUBOOT，偏移会变成 0x10000，`flash.ps1` 必须相应修改**——自检脚本会拦这个。

### 8.2 一键重放

所有对源码树的改动都已固化到 `apply-all.sh`（幂等）：

```bash
bash port/apply-all.sh          # 重放全部移植改动
bash port/apply-all.sh --build  # 应用后直接编译
```

它覆盖（共 18 步，全部幂等）：

| 类别 | 内容 |
|---|---|
| 板级 | `esp32c3_ws2812.c`、`esp_atomic_stubs.c`、**两个** defconfig（`btlight` / `btlight-auto`，各装到 nuttx 和 vendor 两处） |
| 板级补丁 | Make.defs / Kconfig（WS2812 + AUTOSTART）/ bringup（WS2812 初始化 + autostart 任务 + BLE 失败不中断）/ header |
| 树级修补 | `riscv_mtimer` 排除、esp-hal `spinlock_t`、`esp_ble_adapter` 格式、`esp_wireless` 缺头文件、`esp_libc_stubs` noreturn |
| 应用 | `btsh_light`：广播 API 声明、灯珠写入格式、`test` 自检、断开重播、GATT 单次注册、逐灯 RGB |

**不再改动树里的任何 Kconfig**（见 8.3 第 4/5 条）。

#### 可重放性已验证（不是"应该能"）

做过一次真实的"剥离 → 重放"实验：

1. 把 `esp32c3_bringup.c` 里**两段** `#ifdef ..._BTSH_AUTOSTART` 整块删掉（函数 + `kthread_create` 调用）
2. 删掉板级 Kconfig 的 AUTOSTART 段落、header 的声明
3. 删掉两处 `configs/btlight-auto/`
4. 跑 `apply-all.sh`

结果：全部复原，且

```
btlight       : 三处 defconfig 完全一致（port/ · nuttx · vendor）
btlight-auto  : 三处 defconfig 完全一致
重新编译      : 0 错误，产物大小与剥离前完全相同（429,224 / 429,312）
```

说明交付的脚本确实能从"干净的板级改动被清空"的状态重建出同样的固件。

### 8.2b 两个构建变体

| config | 说明 | 大小 | 适用 |
|---|---|---|---|
| **`btlight`**（默认） | 手动在 NSH 里 `btsh_light start` | 429,224 B | 调试期，最安全 |
| **`btlight-auto`** | 开机 3s 后自动广播，无需串口 | 429,312 B | 现场演示 / 独立上电 |

```bash
# 默认（仓库里的 nuttx.bin 就是这个）
./build.sh vendor/espressif/boards/esp32c3/esp32c3-generic/configs/btlight/ -j20

# 自动广播版
./build.sh vendor/espressif/boards/esp32c3/esp32c3-generic/configs/btlight-auto/ -j20
```

`btlight-auto` 对应 `CONFIG_ESP32C3_GENERIC_BTSH_AUTOSTART=y`
（延迟/优先级/栈大小可在 menuconfig 里调）。两个变体都已验证编译通过
（`btlight-auto` 的 ELF 里确认存在 `esp32c3_btsh_autostart` 符号）。

### 8.3 环境级修复清单（这棵树自带的问题，非移植引入）

| # | 问题 | 处理 |
|---|---|---|
| 1 | `prebuilts/gcc` 无 RISC-V 工具链 | 装 `riscv32-esp-elf 13.2.0` + 建 `riscv64-unknown-elf-*` 别名 |
| 2 | `prebuilts/tools/.../riscv64-unknown-elf-gcc` 只是 ccache 空壳 | 不要用 |
| 3 | `prebuilts/kconfig-frontends` 空目录 | 用 `prebuilts/build-tools/linux-x86_64/bin` 里的 `kconfig-conf` |
| 4 | ~~`--help--` typo~~ / ~~`osource` 不支持~~ | ✅ **其实不需要任何修改**。openvela 用的是 Python **kconfiglib**（`prebuilts/tools/python/dist-packages/kconfiglib/`），原生支持 `osource`/`orsource` 和 `--help--`。**切勿**批量替换/删除这些写法——`osource` 指向的文件里可能含配对的 `endif`，改掉会让 if/endif 配对被破坏、`olddefconfig` 失败。误改后还原：`git -C ~/openvela/nuttx checkout -- $(git -C ~/openvela/nuttx diff --name-only \| grep -i kconfig)` |
| 5 | 用错 kconfig 工具（教训） | 我最初用手写的 C 版 `kconfig-conf` 做实验，它不支持 `osource`，据此误判"树里 Kconfig 有语法错误"。**正确工具是 kconfiglib，由 `build.sh` 设置 PYTHONPATH 后调用**；直接调 `configure.sh` 会因 `ModuleNotFoundError` 失败 |
| 6 | `CONFIG_RISCV_TOOLCHAIN` 全树未定义 → `CROSSDEV` 落空 → 用主机 gcc | 构建时 `export CROSSDEV=riscv64-unknown-elf-` |
| 7 | `riscv_mtimer.c` 依赖未启用的 `CONFIG_ONESHOT_COUNT` 接口 | C3 不编译该文件 |
| 8 | 工具链无 `libatomic`（rv32imc 无原子指令） | 提供 `esp_atomic_stubs.c`（单核关中断实现） |
| 9 | `esp_hal` 的 `LOCK_INITIALIZER_UNLOCKED = 0` 对零长数组非法 | 改 `{}` |
| 10 | BLE 代码调用的 `bt_start_advertising` 无公开声明 | 应用内自行 extern 声明 |
| 11 | **`btsh_light_apply()` 灯珠写入格式错误**（功能 bug） | 原实现写 `struct {uint32_t magic; uint8_t r,g,b;}`（对齐 8 字节），驱动把它当成 **2 颗灯**：第 1 颗得到 `0x00AA55`（青绿），第 2 颗垃圾值，**第 3~5 颗完全不更新**。已改为按驱动格式写 `N × 0x00RRGGBB`（`btsh_light` 侧新增 `CONFIG_BTSH_LIGHT_LED_COUNT=5`）。反汇编验证：连写 5 个像素 + `write(..., 20)` |
| 12 | `lederr()` 是内核态宏，应用层不可用 | 应用内改用 `syslog(LOG_ERR, ...)` |
| 13 | **断开连接后不会恢复广播**（功能缺陷） | 控制器建立连接时自动停广播，而 NuttX 协议栈断开后**不会**恢复（`bt_netdev.c` 的回调只打 log）。后果：中心设备连一次再断开，本机永久不可见，只能重启。已通过 `bt_conn_cb_register()` 注册 `disconnected` 回调，在 `LPWORK` 上重播（内核注释明确说不能假定回调线程上下文） |
| 14 | **重复 `start` 会重复注册 GATT 服务** | `bt_gatt_register()` 原本每次 `start` 都调用一次；`start` 两次（或 `stop`+`start`）会把同一服务再插一份到属性表，对端会看到重复服务、句柄错乱。已用 `g_gatt_registered` 守卫，只注册一次 |
| 15 | **BLE 初始化失败会中断整个 bringup** | `esp_bringup()` 里 BLE 失败原本 `return ret`，导致后面的 WS2812 注册、自动广播全部跳过——排障时连 `btsh_light test` 都用不了。已改为记录错误后继续（`ret = OK`） |
| 16 | **控制器→主机流控开启，主机不归还额度** → ACL 数据永远下不来 | 现象：`le_conn_complete status 0` 连接成功，但对端的数据**一个字节都收不到**，30 秒后对端超时断开。修法：`CONFIG_BLUETOOTH_CNTRL_HOST_FLOW_DISABLE=y` |
| 17 | **`bt_att.c` 里 `hdr->code` 是悬垂指针** | `bt_buf_consume(buf, sizeof(*hdr))` 之后 `hdr` 指向已消费内存，查处理函数表时仍用它 → `code` 被改写 → 匹配不到处理函数 → **所有 ATT 请求被静默丢弃**。现象：能连上、服务发现失败、永不应答。修法：consume 前先把 opcode 存进局部变量 |
| 18 | **`gatt_ccc_changed()` 调用 `cfg_changed` 不检查 NULL** | `BT_GATT_CCC()` 第 4 参数传 `NULL` 时，客户端一**开启 NOTIFY（写 CCC 0x2902）** 就调用空函数指针 → `Instruction access fault, EPC=00000000` 整机 PANIC。修法：应用传真实回调 + 协议栈加 NULL 保护 |


### 8.4 板子到货后的验证顺序

1. 只焊电源（Type-C + AMS1117 + C15），量 3.3V 与 VDD（≈4.2V）
2. 焊模组，执行 `flash.ps1 -Port COMx -Erase`（擦除 + 烧 `nuttx.bin` 到 0x0，见第 5 节）
3. 3.3V USB-TTL 接 H1，115200 看 `nsh>` ← **移植成立的判据**
4. `btsh_light state` 确认 `fd=3`（WS2812 已注册）
5. **`btsh_light test`** → 5 颗灯依次 R/G/B/W ← **灯带链路的判据**（分层定位表见 6.2）
6. `btsh_light start`，PC 跑 `tools/ble_client.py --scan` 应扫到 `BTSH-LIGHT`
7. `tools/ble_client.py --selftest` → 全绿说明广播/连接/GATT/读写/通知都通
8. 最后接 A7Z，按 `BLE_PROTOCOL_A7Z.md` 联调

---

## 8.5 广播能力声明（v1.1 新增）

广播数据里除了 Flags，还带一段**厂商自定义数据**，让中心设备不连接即可识别：

```
02 01 06                 ← Flags
07 FF FF FF 01 01 05 07  ← 厂商数据：CompanyID 0xFFFF | ver 1 | 类型 1(灯控) | 5 灯 | caps 0x07
```

能力位：bit0 开关 / bit1 逐灯RGB / bit2 通知。

对应代码：`BTSH_DISCOVERY_ADV`（应用源码）。串口会打印：

```
BTSH: discovery adv: company=0xffff ver=1 type=1 leds=5 caps=0x07
```

中心设备侧解析见 `BLE_PROTOCOL_A7Z.md` §10。


## 9. 硬件实测记录（2026-10-22，首次上板）

板子焊好、首次通电后的完整调试过程与结果。**这一节是"代码能编译"和"板子真能跑"之间的全部差距。**

### 9.1 实测通过的完整功能链

用手机 **nRF Connect** 作为 BLE 中心设备（等价于 A7Z 的角色），实测日志：

```
10:56:34.344  Connecting to DC:DA:0C:82:B8:6E...        ← 链路层连接成功
10:56:34.910  Services discovered                        ← 服务发现成功
              Unknown Service 0000ff00                    ← 我们的灯控服务
              - 0000ff01 [W WNR]                          ← 命令特征
              - 0000ff02 [N R]                            ← 状态特征
                  Client Characteristic Configuration     ← CCC 0x2902
              - 0000ff03 [R]                              ← 设备信息
10:56:47.208  Read Response 0xff03 → (0x) 01-01-00       ← 协议版本/通道数/保留 ✅
10:57:00.175  Read Response 0xff02 → (0x) 00             ← 状态读取 ✅
11:01:54.269  Data written to descr 0x2902 → (0x) 01-00  ← 开启通知成功 ✅
11:01:54.276  Notifications enabled
11:02:13.364  Write 0xff01 → (0x) 00-40-00-00            ← 4 字节逐灯 RGB
              → 第 1 颗 WS2812B 变红 ✅
```

**结论：服务发现、读、写、通知、逐灯 RGB 全部实测通过。**

### 9.1b Windows（WinRT / bleak）实测

手机通过后又暴露出**两个只在 Windows 才复现**的问题（详见 MEMORY.md 4.8）：

| # | 问题 | 现象 |
|---|---|---|
| 4 | 栈里把 MTU 527 判为非法并拒绝 | `connect()` 30 秒超时（服务发现无法开始） |
| 5 | 应用写回调返回 `OK` 而非字节数 | `Protocol Error 0x0E`，但灯其实已亮 |

两个都修好后，Windows 侧 `python tools/ble_client.py --selftest` **全部通过**。

### 9.2 上板前无法发现的问题（三个，全在协议栈里）

| # | 问题 | 上板后的现象 | 定位方法 |
|---|---|---|---|
| 1 | 主机流控开启但额度不归还 | 连接成功、**ACL 数据一个都不来**、30 秒后断开（`reason 19`） | 开 `CONFIG_DEBUG_WIRELESS_INFO` 看 HCI 日志：只有 event、没有 `type 3`（ACL）包 |
| 2 | `bt_att.c` 的 `hdr->code` 悬垂指针 | 能连上，**服务发现永远失败** | 在 `bt_att_receive` 入口打探针：`code` 打印正常，但处理函数查不到 |
| 3 | `gatt_ccc_changed()` 不查 NULL | **一开通知就整机 PANIC**（`EPC=0`） | panic 地址反查：`0x...26fac -> bt_gatt_attr_write_ccc` |

### 9.3 这三个坑的教训

1. **"能连上"和"能用"是两件事。** 广播、链路连接都是控制器的活；ACL 数据、ATT 应答才是主机的活。每一层都要单独验证。
2. **必须有控制台。** 前两轮因为没有日志输出（`CONFIG_SYSLOG_CONSOLE` 没开、协议栈日志也没开），只能靠猜；打开日志后 5 分钟就定位了。
3. **`EPC=00000000` 一律怀疑空函数指针**，用 `addr2line` 反查调用点最快。
4. `CONFIG_DEBUG_WIRELESS_INFO` 会刷屏到影响时序，**定位完要关掉**。

### 9.4 复现这套修复

```bash
bash port/apply-stack-fixes.sh      # 三个协议栈修复 + production 配置，幂等
bash port/apply-discovery-adv.sh    # v1.1 广播能力声明（免连接识别），幂等
./build.sh vendor/espressif/boards/esp32c3/esp32c3-generic/configs/production/ -j20
```

### 9.5 最终固件

```
nuttx-production.bin   429,376 字节   sha256 fa6e7eb7da02b4fd…
出厂自检           : PASS=35  FAIL=0  SKIP=0
```

配置要点（都是实测出来的，不是猜的）：

```
CONFIG_ESPRESSIF_USBSERIAL=y                    # USB 控制台，一根 Type-C 搞定烧录+日志
CONFIG_SYSLOG_CONSOLE=y                         # syslog 输出到控制台
CONFIG_DEVICE_LOCAL_NAME="BTSH-LIGHT"           # ★ 广播名（默认 "NuttX"）
CONFIG_DEVICE_NAME="BTSH-LIGHT"                 # ★ GAP 设备名特征（默认 "Apache NuttX"）
CONFIG_BLUETOOTH_CNTRL_HOST_FLOW_DISABLE=y      # ★ 关流控，否则 ACL 收不到
CONFIG_BLUETOOTH_MAX_CONN=8                     # 连接槽位数（泄漏已修，8 个足够）
CONFIG_ESP32C3_GENERIC_BTSH_AUTOSTART=y         # 开机自动广播
CONFIG_ESP32C3_GENERIC_WS2812=y                 # 灯带
```

### 9.6 已知遗留问题

| 问题 | 影响 | 建议 |
|---|---|---|
| ~~`bt_conn` 槽位泄漏~~ | **已修复**（`bt_conn_reclaim` + 唤醒 TX 线程，见 MEMORY.md 4.9）——实测 **32 次连续连接零失败**，无需再手动复位 | — |
| ~~USB 控制台只能输出不能输入~~ | **实测是好的**（`nsh>` 可正常输入）。之前误判的原因：`serial_log.py` 是**只读**日志工具（为保证绝不触发复位而不写串口），在那个窗口敲键盘自然没反应。要敲命令请用 `python tools/console.py -p COM6` | — |