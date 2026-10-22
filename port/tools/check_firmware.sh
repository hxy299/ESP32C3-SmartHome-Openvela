#!/usr/bin/env bash
#============================================================================
# ESP32-C3-SmartHome-Actuator  固件出厂自检
#
# 在编译完成后运行，逐项检查"这个固件能不能上板"。全部 PASS 才算可烧录。
# 不依赖硬件，纯静态检查（ELF + .config + 二进制内容）。
#
# 用法:
#   bash port/tools/check_firmware.sh                # 检查默认位置
#   VELA_ROOT=~/openvela bash port/tools/check_firmware.sh
#
# 退出码: 0 = 全部通过；1 = 有 FAIL
#============================================================================
set -u
V=${VELA_ROOT:-$HOME/openvela}
N=$V/nuttx
ELF=$N/nuttx
BIN=$N/nuttx.bin
CFG=$N/.config

export PATH="${PATH}:/usr/bin:/bin"
if command -v riscv64-unknown-elf-nm >/dev/null 2>&1; then
  :
else
  export PATH="$HOME/tc-bin:$HOME/riscv32-esp-elf/bin:$PATH"
fi

NM=${NM:-riscv64-unknown-elf-nm}
OD=${OD:-riscv64-unknown-elf-objdump}
RE=${RE:-riscv64-unknown-elf-readelf}

pass=0; fail=0; skip=0

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
note() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; skip=$((skip+1)); }

sec() { printf '\n\033[1m%s\033[0m\n' "$1"; }

#----------------------------------------------------------------------------
sec "[1] 产物存在性"
[ -f "$ELF" ] && ok "nuttx ELF 存在" || bad "nuttx ELF 不存在（先编译）"
[ -f "$BIN" ] && ok "nuttx.bin 存在" || bad "nuttx.bin 不存在"
[ -f "$CFG" ] && ok ".config 存在"   || bad ".config 不存在"

if [ "$fail" -gt 0 ]; then
  printf '\n\033[31m产物不全，后续检查跳过。\033[0m\n'; exit 1
fi

#----------------------------------------------------------------------------
sec "[2] 目标架构"
$RE -h "$ELF" 2>/dev/null | grep -q 'RISC-V' \
  && ok "ELF 是 RISC-V" || bad "ELF 不是 RISC-V"
grep -q '^CONFIG_ARCH_CHIP="esp32c3"' "$CFG" \
  && ok 'ARCH_CHIP="esp32c3"' || bad "ARCH_CHIP 不是 esp32c3"
grep -q '^CONFIG_ESPRESSIF_CHIP_SERIES="esp32c3"' "$CFG" \
  && ok 'CHIP_SERIES="esp32c3"' || bad "CHIP_SERIES 不对"
grep -q '^CONFIG_ARCH_RV32=y' "$CFG" && ok "RV32" || bad "不是 RV32"

#----------------------------------------------------------------------------
sec "[3] 镜像布局（决定烧录偏移）"
ENTRY=$($RE -h "$ELF" 2>/dev/null | awk '/Entry point/{print $NF}')
if [ -n "${ENTRY:-}" ]; then
  # ESP32-C3 IRAM 0x40380000 起
  if [ "$((ENTRY))" -ge "$((0x40380000))" ] && [ "$((ENTRY))" -lt "$((0x403A0000))" ]; then
    ok "入口点 $ENTRY 落在 IRAM"
  else
    bad "入口点 $ENTRY 不在 IRAM 范围"
  fi
else
  bad "读不到入口点"
fi

grep -q '^CONFIG_ESPRESSIF_SIMPLE_BOOT=y' "$CFG" \
  && ok "SIMPLE_BOOT（直接启动，无需二级 bootloader）" \
  || bad "不是 SIMPLE_BOOT，烧录方式要改"

# 检查 MMU 约束：flash 段的 LMA/VMA 低 16 位必须相等
python3 - "$ELF" <<'PYEOF'
import re, subprocess, sys
elf = sys.argv[1]
out = subprocess.run(['riscv64-unknown-elf-readelf', '-l', elf],
                     capture_output=True, text=True).stdout
bad = 0
checked = 0
for line in out.splitlines():
    if not line.startswith('  LOAD'): continue
    p = line.split()
    vma = int(p[2], 16); lma = int(p[3], 16)
    # 只关心 flash 映射段（VMA 在 0x3C000000 / 0x42000000 附近）
    if not (0x3C000000 <= vma < 0x3D000000 or 0x42000000 <= vma < 0x43000000):
        continue
    checked += 1
    if (vma & 0xFFFF) != (lma & 0xFFFF):
        bad += 1
        print('  \033[31mFAIL\033[0m  MMU 约束破坏: VMA=0x%08X LMA=0x%08X' % (vma, lma))
if bad == 0:
    print('  \033[32mPASS\033[0m  flash 段满足 MMU 约束（VMA%%64K == LMA%%64K），共 %d 段' % checked)
sys.exit(1 if bad else 0)
PYEOF
[ $? -eq 0 ] && pass=$((pass+1)) || fail=$((fail+1))

python3 - "$ELF" "$BIN" <<'PYEOF'
import os, re, subprocess, sys
elf, bin_ = sys.argv[1], sys.argv[2]

# 用 section 判断而不是 LOAD 段：LOAD 的 filesz 含对齐填充，
# 真正决定"要烧多少字节"的是最后一个有内容的 flash 映射 section。
out = subprocess.run(['riscv64-unknown-elf-readelf', '-S', elf],
                     capture_output=True, text=True).stdout
end = 0
last = ''
for line in out.splitlines():
    m = re.match(r'\s*\[\s*\d+\]\s+(\S+)\s+(PROGBITS|NOBITS)\s+'
                 r'([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)', line)
    if not m:
        continue
    name, typ, vma, off, size = m.groups()
    if typ != 'PROGBITS':
        continue
    vma = int(vma, 16); off = int(off, 16); size = int(size, 16)
    if size == 0:
        continue
    if not ((0x3C000000 <= vma < 0x3D000000) or (0x42000000 <= vma < 0x43000000)):
        continue
    if off + size > end:
        end = off + size
        last = name

size = os.path.getsize(bin_)
if end and size >= end:
    extra = size - end
    print('  \033[32mPASS\033[0m  镜像 %d 字节覆盖全部 flash 内容（结束 0x%X, %s）%s'
          % (size, end, last, '，尾部多 %d 字节元数据' % extra if extra else ''))
    sys.exit(0)
print('  \033[31mFAIL\033[0m  镜像 %d 字节 < flash 内容结束 0x%X (%s) —— 尾部会被截断'
      % (size, end, last))
sys.exit(1)
PYEOF
case $? in 0) pass=$((pass+1));; 2) skip=$((skip+1));; *) fail=$((fail+1));; esac

#----------------------------------------------------------------------------
sec "[4] 必备功能符号"
SYMS="nsh_main nsh_consolemain bt_gatt_register bt_start_advertising \
btsh_light_main board_ws2812_initialize ws2812_leds_register esp_ble_initialize"
missing=""
for s in $SYMS; do
  $NM "$ELF" 2>/dev/null | grep -qw "$s" || missing="$missing $s"
done
[ -z "$missing" ] && ok "全部核心符号存在" || bad "缺符号:$missing"

# 可能被内联的功能，用字符串间接确认
check_str() {
  if strings -a "$ELF" 2>/dev/null | grep -q "$1"; then
    ok "固件内含: $1"
  else
    bad "固件内缺: $1"
  fi
}
sec "[5] 功能要素（字符串级）"
check_str 'BTSH-LIGHT'
check_str 'WS2812 self-test'
check_str 'Usage: btsh_light <start|stop|state|test>'
check_str 'BTSH: discovery adv'        # 广播能力声明（v1.1 免连接识别）
check_str 'BTSH: CCC changed'          # CCC 回调存在 = 开通知不会崩
check_str 'BTSH: central disconnected'  # 连接状态回调存在
check_str 'rgb write failed'

#----------------------------------------------------------------------------
sec "[6] 灯带配置一致性（三处必须相同）"
NL1=$(grep -oP '(?<=^CONFIG_WS2812_LED_COUNT=)\d+' "$CFG" 2>/dev/null || echo "?")
NL2=$(grep -oP '(?<=^CONFIG_ESP32C3_GENERIC_WS2812_NLEDS=)\d+' "$CFG" 2>/dev/null || echo "?")
NL3=$(grep -oP '(?<=^CONFIG_BTSH_LIGHT_LED_COUNT=)\d+' "$CFG" 2>/dev/null || echo "?")
if [ "$NL1" = "$NL2" ] && [ "$NL2" = "$NL3" ] && [ "$NL1" != "?" ]; then
  ok "灯珠数量一致: WS2812_LED_COUNT=$NL1 / GENERIC_NLEDS=$NL2 / BTSH_LED_COUNT=$NL3"
else
  bad "灯珠数量不一致: $NL1 / $NL2 / $NL3"
fi

FP=$(grep -oP '(?<=^CONFIG_WS2812_FREQUENCY=)\d+' "$CFG" 2>/dev/null || echo 0)
if [ "$FP" -ge 5900000 ] && [ "$FP" -le 9000000 ]; then
  ok "WS2812 频率 $FP 落在 5.9–9 MHz 档（T0H≈250ns / T1H≈625ns）"
elif [ "$FP" -ge 3600000 ] && [ "$FP" -le 5000000 ]; then
  ok "WS2812 频率 $FP 落在 3.6–5 MHz 档"
else
  bad "WS2812 频率 $FP 不在驱动支持范围（会编译报错或时序不合规）"
fi

grep -q '^CONFIG_ESPRESSIF_SPI2_MOSIPIN=4' "$CFG" \
  && ok "WS2812 数据脚 = GPIO4" || bad "SPI2 MOSI 不是 GPIO4"

#----------------------------------------------------------------------------
sec "[7] 控制台（nsh 的前提）"

# 两种合法形态：
#   A) UART0 控制台（H1 排针，GPIO21/20，需要 3.3V USB-TTL）
#   B) USB-Serial-JTAG 控制台（同一根 Type-C，需要 CONFIG_ESPRESSIF_USBSERIAL）
if grep -q '^CONFIG_UART0_SERIAL_CONSOLE=y' "$CFG"; then
  ok "控制台形态 A：UART0（H1 排针）"
  grep -q '^CONFIG_UART0_BAUD=115200' "$CFG" && ok "波特率 115200" || bad "波特率不是 115200"
  TX=$(grep -oP '(?<=^CONFIG_ESPRESSIF_UART0_TXPIN=)\d+' "$CFG" 2>/dev/null || echo "?")
  RX=$(grep -oP '(?<=^CONFIG_ESPRESSIF_UART0_RXPIN=)\d+' "$CFG" 2>/dev/null || echo "?")
  if [ "$TX" = "21" ] && [ "$RX" = "20" ]; then
    ok "UART0 TX=GPIO$TX / RX=GPIO$RX（与 H1 排针一致）"
  else
    bad "UART0 引脚 TX=$TX RX=$RX，与板子 H1(GPIO20/21) 不符"
  fi
elif grep -q '^CONFIG_ESPRESSIF_USBSERIAL=y' "$CFG"; then
  ok "控制台形态 B：USB-Serial-JTAG（同一根 Type-C 线）"
  grep -q '^CONFIG_OTHER_SERIAL_CONSOLE=y' "$CFG" \
    && ok "OTHER_SERIAL_CONSOLE（USB 已选为控制台）" \
    || bad "USBSERIAL 已开但不是控制台（OTHER_SERIAL_CONSOLE 未选）"
  $NM "$ELF" 2>/dev/null | grep -qw 'g_uart_usbserial' \
    && ok "g_uart_usbserial 驱动已链接" || bad "g_uart_usbserial 缺失"
  if grep -q '^CONFIG_UART0_SERIAL_CONSOLE=y' "$CFG"; then
    bad "同时开了 UART0 与 USB 控制台，可能冲突"
  fi
else
  bad "没有任何控制台（既无 UART0 也无 USB-SERIAL-JTAG）"
fi

grep -q '^CONFIG_INIT_ENTRYPOINT="nsh_main"' "$CFG" && ok "init 入口 = nsh_main" || bad "init 入口不是 nsh_main"
grep -q '^CONFIG_NSH_ARCHINIT=y' "$CFG"            && ok "NSH_ARCHINIT（会触发板级 bringup）" || bad "NSH_ARCHINIT 未开 → bringup 不会跑"
grep -q '^CONFIG_BOARDCTL=y' "$CFG"                && ok "BOARDCTL" || bad "BOARDCTL 未开"

#----------------------------------------------------------------------------
sec "[8] BLE 配置"
grep -q '^CONFIG_ESPRESSIF_BLE=y' "$CFG"              && ok "ESP32-C3 BLE 控制器" || bad "BLE 未启用"
grep -q '^CONFIG_WIRELESS_BLUETOOTH_HOST=y' "$CFG"    && ok "BT host 协议栈"     || bad "BT host 未启用"
grep -q '^CONFIG_BTSH_LIGHT=y' "$CFG"                 && ok "btsh_light 应用"    || bad "btsh_light 未启用"
MC=$(grep -oP '(?<=^CONFIG_BLUETOOTH_MAX_PAIRED=)\d+' "$CFG" 2>/dev/null || echo 0)
[ "$MC" -ge 1 ] && ok "MAX_PAIRED=$MC（CCC 数组非零长度，notify 可用）" \
                || bad "MAX_PAIRED=0 → CCC 数组长度为 0，notify 不可用"
grep -q '^CONFIG_SCHED_LPWORK=y' "$CFG" \
  && ok "LPWORK 工作队列（断开重播需要）" || bad "LPWORK 未开 → 断开后无法重播广播"

#----------------------------------------------------------------------------
sec "[9] 启动路径（错了就是上电不亮/跑飞）"

# 9a) .bss 必须在运行期被清零。SIMPLE_BOOT 下 esp_start.c 调用的是
#     bootloader_init()，而 bss 清零发生在它内部；若那条调用消失，
#     所有全局变量初值都是垃圾。这里直接查机器码。
if $OD -d "$ELF" 2>/dev/null | awk '/<bootloader_init>:/{f=1} f&&/bootloader_clear_bss_section/{found=1} f&&/^$/{exit} END{exit !found}'; then
  ok "bootloader_init() 内调用了 bootloader_clear_bss_section()"
else
  bad "bootloader_init() 没清 bss → 全局变量初值是垃圾"
fi

BSS_S=$($NM "$ELF" 2>/dev/null | awk '/ _bss_start$/{print "0x"$1}')
BSS_E=$($NM "$ELF" 2>/dev/null | awk '/ _bss_end$/{print "0x"$1}')
if [ -n "$BSS_S" ] && [ -n "$BSS_E" ]; then
  if [ "$((BSS_E))" -gt "$((BSS_S))" ] && \
     [ "$((BSS_S))" -ge "$((0x3FC80000))" ] && [ "$((BSS_E))" -lt "$((0x3FCE0000))" ]; then
    ok "bss 范围 $BSS_S..$BSS_E 合法（$(printf '%d' $((BSS_E-BSS_S))) 字节，在 DRAM 内）"
  else
    bad "bss 范围异常: $BSS_S..$BSS_E"
  fi
else
  bad "找不到 _bss_start / _bss_end"
fi

# 9b) SIMPLE_BOOT 下 PRIMARY_SLOT_OFFSET 被强制为 0（esp_start.c），
#     所以 flash 映射段的实际烧录地址 == LMA。要求 LMA 64KB 对齐。
IR_LMA=$($NM "$ELF" 2>/dev/null | awk '/ _image_irom_lma$/{print "0x"$1}')
DR_LMA=$($NM "$ELF" 2>/dev/null | awk '/ _image_drom_lma$/{print "0x"$1}')
if [ -n "$IR_LMA" ] && [ -n "$DR_LMA" ]; then
  if [ $((IR_LMA % 0x10000)) -eq 0 ] && [ $((DR_LMA % 0x10000)) -eq 0 ]; then
    ok "XIP 段 LMA 64KB 对齐: irom=$IR_LMA drom=$DR_LMA（PRIMARY_SLOT_OFFSET=0 → 烧到 0x0）"
  else
    bad "XIP 段 LMA 未 64KB 对齐: irom=$IR_LMA drom=$DR_LMA"
  fi
else
  note "找不到 _image_irom_lma / _image_drom_lma（版本差异，非致命）"
fi

if grep -q '^CONFIG_ESPRESSIF_BOOTLOADER_MCUBOOT=y' "$CFG"; then
  bad "启用了 MCUBOOT：烧录偏移不再是 0x0，flash.ps1 需调整"
fi


#----------------------------------------------------------------------------
printf '\n\033[1m结果: PASS=%d  FAIL=%d  SKIP=%d\033[0m\n' "$pass" "$fail" "$skip"
if [ "$fail" -gt 0 ]; then
  printf '\033[31m有 %d 项失败，不建议烧录。\033[0m\n' "$fail"
  exit 1
fi
printf '\033[32m全部通过，可以烧录：port/flash.ps1 -Port COMx -Erase\033[0m\n'
exit 0
