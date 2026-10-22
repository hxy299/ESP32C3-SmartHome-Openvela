# openvela 适配 ESP32-C3 资料清单

> 目标：把 openvela 跑在 ESP32-C3（自研智能家居板）上。
> 本文是"开工前要准备什么"的清单，含现状盘点、必备资料、关键决策和最小 bringup 路线。

---

## 0. 先看现状（很重要，能省掉一大半力气）

查过 openvela 内核仓 `open-vela/nuttx` 的 `dev` 分支后确认：

| 层 | 是否已有 ESP32-C3 | 位置 |
|---|---|---|
| 架构层 RISC-V | 已有 | `arch/risc-v/src/common`、`common/espressif` |
| 芯片层（新 port） | **已有** | `arch/risc-v/src/esp32c3`（基于 espressif `esp-hal-3rdparty`） |
| 芯片层（旧 port） | **已有** | `arch/risc-v/src/esp32c3-legacy`（自包含，外设齐全，含 `Kconfig.security`） |
| 板级层（新 port） | **已有** | `boards/risc-v/esp32c3/esp32c3-generic`，自带 20+ 个 defconfig |
| 板级层（旧 port） | **已有** | `boards/risc-v/esp32c3-legacy/esp32c3-devkit`、`esp32c3-devkit-rust-1` |
| 官方"已支持"认证 | **没有** | openvela《开发板支持列表》只列了 STM32H750/F411、ESP32-S3-EYE、ESP32-S3-BOX 等 |
| 现成 vendor 仓 | **没有 C3** | `open-vela/vendor_espressif` 目前只有 `boards/esp32s3` |

**结论：ESP32-C3 的芯片驱动和通用板级代码都已经在树里（继承自上游 Apache NuttX），你不需要从零写芯片层。**
适配工作的实际重心是：

1. 选 port（`esp32c3` vs `esp32c3-legacy`）和选 openvela 分支；
2. 按 openvela 规范在 `vendor/` 下建**你自己的板级目录**（defconfig / board.h / 链接脚本 / 板级初始化）；
3. 打通"串口 → 烧录 → 网络"这条链路；
4. 加自家外设驱动和应用，过准入门槛测试。

已在树内的 defconfig（`boards/risc-v/esp32c3/esp32c3-generic/configs/`）：
`nsh`、`wifi`、`ble`、`sta_softap`、`usbconsole`、`spiflash`、`mcuboot_nsh`、`tickless`、`timers`、`pwm`、`rmt`、`rtc`、`i2c`、`spi`、`gpio`、`buttons`、`twai`、`watchdog`、`random`、`ostest`、`bmp180`、`temperature_sensor`。
→ **`nsh` 和 `wifi` 这两个直接就是你的起点，抄它们改引脚即可。**

---

## 1. 源码与第三方库

| # | 资料 | 获取方式 | 用途 |
|---|---|---|---|
| 1 | openvela 主仓 + `build.sh` | [快速入门](https://doc.openvela.com/document?id=201&language=cn) | 拉源码、统一构建入口 |
| 2 | [open-vela/nuttx](https://github.com/open-vela/nuttx/tree/dev) `dev` 分支 | `repo` 同步 | 内核 + C3 芯片层 + `esp32c3-generic` 板级层 |
| 3 | [open-vela/vendor_template](https://github.com/open-vela/vendor_template) | git clone | **vendor 目录适配模板（你的主战场）** |
| 4 | [open-vela/vendor_espressif](https://github.com/open-vela/vendor_espressif) | git clone | 最接近的乐鑫参考实现（`boards/esp32s3/esp32s3-eye`，含可用 Wi-Fi defconfig） |
| 5 | [espressif/esp-hal-3rdparty](https://github.com/espressif/esp-hal-3rdparty) | 构建时自动 clone | **必需**：HAL 源码 + WiFi/BLE 预编译库 |
| 6 | [espressif/esp-nuttx-bootloader](https://github.com/espressif/esp-nuttx-bootloader) | 构建时自动拉取 | 二级 bootloader + 分区表 bin |
| 7 | openvela apps / packages | manifest | `nsh`、`iperf`、`dhcpc`、`wapi` 等现成应用 |
| 8 | [open-vela/external_zblue](https://github.com/open-vela/external_zblue) | manifest | BLE 主机协议栈（智能家居配网需要时才用） |
| 9 | [espressif/esp-idf](https://github.com/espressif/esp-idf) | 参考用 | 查分区表/bootloader/PHY 校准/eFuse 语义 |

### 关于第 5、6 条（编译期会自动下载，但你要知道它在干什么）

`arch/risc-v/src/common/espressif/Make.defs` 里写死了：

- 仓库：`https://github.com/espressif/esp-hal-3rdparty.git`
- 默认版本：`9fc713a95b1ff150dd0b0647e465d3c624056bb1`（可用 `ESP_HAL_3RDPARTY_VERSION` 覆盖）
- 克隆到 `nuttx/arch/risc-v/src/esp32c3/chip/esp-hal-3rdparty`
- 无线功能开启时还会 init 这些子模块：
  `components/mbedtls/mbedtls`、`components/esp_phy/lib`、`components/esp_wifi/lib`、`components/bt/controller/lib_esp32c3_family`、`components/esp_coex/lib`
  并给 mbedtls 打 `nuttx/patches/components/mbedtls/mbedtls/*.patch`

Wi-Fi / BLE 的预编译库就是从这里来的（`arch/risc-v/src/esp32c3/Make.defs`）：

```make
ifeq ($(CONFIG_ESPRESSIF_WIFI),y)
  EXTRA_LIBS += -lcore -lnet80211 -lpp
endif
ifeq ($(CONFIG_ESPRESSIF_BLE),y)
  EXTRA_LIBS += -lbtbb -lbtdm_app
endif
```

> ⚠️ **内网/离线编译必读**：构建期需要访问 GitHub。离线环境要提前把 `esp-hal-3rdparty` 放到 `nuttx/nxtmpdir/`，
> 并设 `USE_NXTMPDIR_ESP_REPO_DIRECTLY=y`（见同一份 Make.defs 的 `NXTMPDIR` 分支）。

`arch/risc-v/src/esp32c3/.gitignore` 也印证了这些是构建期产物：
`/bootloader`、`/esp-nuttx-bootloader`、`/*.zip`、`/esp-hal-3rdparty`。

---

## 2. 工具链与烧录/调试工具

| 工具 | 说明 |
|---|---|
| `riscv32-esp-elf-gcc` | ESP32-C3 是 RISC-V。**用乐鑫 crosstool-NG 版本**（如 `esp-12.2.0_20230208` 或更新），与 `esp-hal-3rdparty` 预编译库 ABI 保持一致；上游文档提到通用 SiFive 工具链，但一旦启用 Wi-Fi/BLE 预编译库就会踩 ABI 坑 |
| `esptool` | `pip install esptool`，强烈建议放在 venv 里 |
| `espefuse.py` | 随 esptool。C3 ECO3 之前要烧 `DIS_USB_JTAG` 才能用 JTAG 调试 |
| `openocd-esp32` | 乐鑫分支，`board/esp32c3-builtin.cfg`；ECO3 及以后内置 USB-JTAG，不用外接调试器 |
| `git` / `make` / `cmake` / `python3` / build 工具链 | openvela 支持 Make 与 CMake 两种构建，推荐 CMake |
| 串口终端 | minicom / PuTTY，115200 |

**烧录地址（记牢）**：`0x0` bootloader、`0x8000` 分区表、`0x10000` 应用 bin。
构建系统已封装：`make flash ESPTOOL_PORT=<port> ESPTOOL_BINDIR=<bootloader 所在目录>`（bootloader 只需烧一次）。

---

## 3. 硬件资料（芯片 + 板级）

**芯片/模组**
- ESP32-C3 Datasheet
- ESP32-C3 技术参考手册（TRM）
- ESP32-C3 系列 ECO 版本与 errata（决定 USB-JTAG 用法、已知 bug 规避）
- ESP32-C3-MINI-1 / ESP32-C3-WROOM-02 模组规格书（天线、Flash 容量、供电要求）

**板级**
- 官方 `ESP32-C3-DevKitC-02` / `DevKitM-1` 原理图（对照 strapping 脚、USB、LED、按键）
- **你们自研板的原理图 + BOM + 管脚分配表** ← `board.h` 的直接输入
- Flash 型号 / 容量 / SPI 模式（QIO/DIO、频率）与**分区表规划**
- 板载外设 datasheet：传感器（I2C/SPI/ADC）、继电器/可控硅、LED/WS2812、按键
- 晶振与时钟树、射频匹配与天线（做 Wi-Fi/BLE 认证时是硬门槛）
- 供电与功耗预算

**内存现实（务必先算账）**
ESP32-C3 = 400KB SRAM + 8KB RTC SRAM，**没有 PSRAM**。
对照官方 ESP32-S3-EYE 的 Wi-Fi defconfig 里 `CONFIG_RAM_SIZE=114688` 这类配置，openvela 全量组件大概率塞不进 C3。
内存预算是本项目最大的技术风险，建议在选 port 之前先做一版裁剪后的镜像体积评估。

---

## 4. openvela 官方文档（按落地顺序读）

| 顺序 | 文档 | 为什么读 |
|---|---|---|
| 1 | [快速入门](https://doc.openvela.com/document?id=201&language=cn) | 拉源码、环境搭建 |
| 2 | [新平台适配指南](https://doc.openvela.com/document?id=602&language=cn) | **主文档**：三层架构、chip/board 适配步骤、构建产物（`libarch.a`/`libboard.a`/`vela_nuttx.bin`） |
| 3 | [Vendor 目录和文件](https://doc.openvela.com/document?id=604&language=cn) | 定制代码必须放 `vendor/`，不许改核心仓 |
| 4 | [在 ESP32-S3-EYE 上移植 openvela 并启用 Wi-Fi](https://doc.openvela.com/document?id=212&language=cn) | **最接近的乐鑫实操案例**：工具链、esptool venv、vendor defconfig、`build.sh`、`make flash`、`ifconfig` 看到 `wlan0` |
| 5 | [开发板支持列表](https://doc.openvela.com/document?id=209&language=cn) | 确认 C3 不在官方列表内（影响支持预期） |
| 6 | [启动流程](https://doc.openvela.com/document?id=614&language=cn) | `board_early_initialize` / `late` / `app_initialize` 分别在什么上下文跑 |
| 7 | [串口驱动适配指南](https://doc.openvela.com/document?id=648&language=cn) | bringup 第一关，控制台出不来后面全免谈 |
| 8 | [中断系统适配指南](https://doc.openvela.com/document?id=603&language=cn) | `up_*` 中断接口 |
| 9 | [Arch_Alarm 框架](https://doc.openvela.com/document?id=654&language=cn) / [Arch Timer 框架](https://doc.openvela.com/document?id=653&language=cn) | 时钟/定时器（含 tickless） |
| 10 | [Kconfig 使用指南](https://doc.openvela.com/document?id=609&language=cn) | 写 defconfig 的前提 |
| 11 | [NuttX ESP32-C3 平台文档](https://nuttx.apache.org/docs/latest/platforms/risc-v/esp32c3/index.html) | 上游端口细节、bootloader/分区表、OpenOCD、外设支持矩阵 |
| 12 | NuttX 板级文档 `boards/risc-v/esp32c3-legacy/esp32c3-devkit` | 旧 port 的配置说明 |

---

## 5. 开工前必须敲定的 6 个决策

1. **选哪个 port？**
   - `arch/risc-v/src/esp32c3`（新）：基于 `esp-hal-3rdparty`，与官方 S3 路线一致，Wi-Fi/BLE 走乐鑫预编译库；chip 级 Kconfig 极简（配置在 `common/espressif/Kconfig`）。
   - `arch/risc-v/src/esp32c3-legacy`（旧）：自包含，外设更全，且带 `Kconfig.security`（安全启动 / Flash 加密等约 12KB 配置项）。
   - 经验判断：**要外设齐 + 要安全启动/加密 → legacy；要跟官方 S3 路线长期演进 → 新 port。**
2. **openvela 用哪个分支？** `trunk`（官方文档对应）/ `dev`（C3 代码确认存在）/ `dev-ai-contest-2026`。
3. **是否要 Wi-Fi / BLE？** 决定要不要 `esp-hal-3rdparty` 无线子模块、`wapi`、`zblue`。
4. **先在官方 `ESP32-C3-DevKitC-02` 上跑通，还是直接上自研板？** 强烈建议前者，先把工具链/烧录变量排除掉。
5. **量产需求**：OTA（A/B、`mcuboot_nsh` 配置）、安全启动、Flash 加密、是否要走开放原子/openvela 准入测试（功能+稳定性+性能）。
6. **内存预算**：见上文风险提示，先评估再选 port。

---

## 6. 建议的最小 bringup 路线

1. **打通链路**：源码 + `riscv32-esp-elf` + esptool 就绪 → 直接编 `esp32c3-devkit:nsh`（或 `esp32c3-generic:nsh`）→ 在 DevKitC-02 上看到 `nsh>` 提示符。
   这一步不改任何代码，只证明工具链、bootloader、烧录地址、串口都是对的。
2. **建自己的 vendor 目录**：照 `vendor_template` 建
   `vendor/<你的厂商>/boards/esp32c3/<board>/configs/nsh/defconfig`
   只改引脚、时钟、内存布局、链接脚本。
3. **触发网络**：切到 `wifi` defconfig（或参考 `vendor_espressif` 的 S3 Wi-Fi defconfig），`ifconfig` 出现 `wlan0`。
4. **加外设**：按 `board_early_initialize` → `board_late_initialize` → `board_app_initialize` 的阶段划分挂传感器/继电器/LED 驱动。
5. **上应用与配置**：`appinit` 里拉起你的智能家居逻辑（配网、MQTT、本地控制）。
6. **准入验证**：功能 / 稳定性 / 性能测试，再考虑 OTA 与安全启动。

---

## 7. 自查清单（动手前逐条打勾）

- [ ] `riscv32-esp-elf-gcc -v` 有输出，版本与 `esp-hal-3rdparty` 匹配
- [ ] `python -m esptool version` 可用（venv 已激活）
- [ ] 网络可达 github.com（构建期要 clone `esp-hal-3rdparty`）；否则已预置 `nxtmpdir` + `USE_NXTMPDIR_ESP_REPO_DIRECTLY=y`
- [ ] 选定 port（`esp32c3` / `esp32c3-legacy`）与 openvela 分支
- [ ] 拿到自研板原理图 + 管脚表 + Flash 型号 + 分区规划
- [ ] 芯片 TRM / Datasheet / ECO 版本说明已下载
- [ ] `esp32c3-generic:nsh` 在官方 DevKit 上跑通（基线）
- [ ] 内存预算评估完成（400KB SRAM 无 PSRAM，够不够）
- [ ] 明确 Wi-Fi/BLE/OTA/安全启动 是否需要，以及是否要过准入测试
