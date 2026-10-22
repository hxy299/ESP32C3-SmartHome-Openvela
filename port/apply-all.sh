#!/usr/bin/env bash
#============================================================================
# ESP32-C3-SmartHome-Actuator : openvela 移植一键应用脚本
#
# 在已有的 openvela 源码树（~/openvela）上重放全部移植改动。
# 幂等：可重复执行。
#
# 用法:
#   bash port/apply-all.sh              # 应用全部改动
#   bash port/apply-all.sh --build      # 应用后直接编译
#============================================================================
set -e

PORT="$(cd "$(dirname "$0")" && pwd)"
V="${VELA_ROOT:-$HOME/openvela}"
N="$V/nuttx"
CHIP="$N/arch/risc-v/src/esp32c3"
BOARD="$N/boards/risc-v/esp32c3/esp32c3-generic"
VBOARD="$V/vendor/espressif/boards/esp32c3/esp32c3-generic"

test -d "$N" || { echo "ERROR: openvela tree not found at $V"; exit 1; }

echo "=========================================================="
echo " openvela -> ESP32-C3-WROOM-02-N4 (ESP32-C3-SmartHome-Actuator)"
echo " tree: $V"
echo "=========================================================="

#----------------------------------------------------------------------------
echo "[1/9] 板级 WS2812 文件 + 板级配置"
cp -f "$PORT/esp32c3_ws2812.c"        "$BOARD/src/esp32c3_ws2812.c"
cp -f "$PORT/esp_atomic_stubs.c"      "$CHIP/esp_atomic_stubs.c"
mkdir -p "$BOARD/configs/btlight" "$BOARD/configs/btlight-auto"
cp -f "$PORT/defconfig-btlight"       "$BOARD/configs/btlight/defconfig"
cp -f "$PORT/defconfig-btlight-auto"  "$BOARD/configs/btlight-auto/defconfig"

# vendor 层（官方文档要求：defconfig 属于 vendor/<vendor>/boards/<chip>/<board>）
mkdir -p "$VBOARD/configs/btlight" "$VBOARD/configs/btlight-auto" "$VBOARD/scripts"
cp -f "$PORT/defconfig-btlight"       "$VBOARD/configs/btlight/defconfig"
cp -f "$PORT/defconfig-btlight-auto"  "$VBOARD/configs/btlight-auto/defconfig"
cp -f "$BOARD/scripts/Make.defs"      "$VBOARD/scripts/Make.defs"

#----------------------------------------------------------------------------
echo "[2/9] 板级 Make.defs / Kconfig / bringup / header 补丁"
python3 - "$BOARD" "$CHIP" <<'PYEOF'
import io, os, sys
board, chip = sys.argv[1], sys.argv[2]
src = os.path.join(board, 'src')

def edit(path, anchor, add, marker, where='before'):
    s = io.open(path, encoding='utf-8').read()
    if marker in s:
        return 'skip'
    assert anchor in s, 'anchor not found in ' + path
    s = s.replace(anchor, add + anchor, 1) if where == 'before' else s.replace(anchor, anchor + add, 1)
    io.open(path, 'w', encoding='utf-8').write(s)
    return 'ok'

# src/Make.defs : 编译 WS2812 与 atomic stub
mk = os.path.join(src, 'Make.defs')
s = io.open(mk, encoding='utf-8').read()
if 'esp32c3_ws2812.c' not in s:
    s += ('\nifeq ($(CONFIG_WS2812),y)\n'
          '  ifneq ($(CONFIG_WS2812_NON_SPI_DRIVER),y)\n'
          '    CSRCS += esp32c3_ws2812.c\n'
          '  endif\nendif\n')
    io.open(mk, 'w', encoding='utf-8').write(s)
    print('  Make.defs: +ws2812')

# chip/Make.defs : atomic stubs
cmk = os.path.join(chip, 'Make.defs')
s = io.open(cmk, encoding='utf-8').read()
if 'esp_atomic_stubs.c' not in s:
    s = s.rstrip() + ('\n\n# rv32imc has no atomics and the toolchain has no libatomic\n'
                      'CHIP_CSRCS += esp_atomic_stubs.c\n')
    io.open(cmk, 'w', encoding='utf-8').write(s)
    print('  chip/Make.defs: +atomic stubs')

# 板级 Kconfig
kc = os.path.join(board, 'Kconfig')
s = io.open(kc, encoding='utf-8').read()
if 'ESP32C3_GENERIC_WS2812' not in s:
    add = '''config ESP32C3_GENERIC_WS2812
\tbool "WS2812 LED strip support"
\tdefault n
\tdepends on WS2812
\t---help---
\t\tWS2812 strip on this board, driven through SPI2 MOSI
\t\t(pin from CONFIG_ESPRESSIF_SPI2_MOSIPIN).

if ESP32C3_GENERIC_WS2812

config ESP32C3_GENERIC_WS2812_NLEDS
\tint "Number of chained WS2812 LEDs"
\tdefault 5
\trange 1 1024

endif # ESP32C3_GENERIC_WS2812

'''
    s = s.replace('endif # ARCH_BOARD_ESP32C3_GENERIC', add + 'endif # ARCH_BOARD_ESP32C3_GENERIC', 1)
    io.open(kc, 'w', encoding='utf-8').write(s)
    print('  Kconfig: +WS2812')

# bringup
br = os.path.join(src, 'esp32c3_bringup.c')
s = io.open(br, encoding='utf-8').read()
if 'board_ws2812_initialize' not in s:
    marker = '  /* If we got here then perhaps not all initialization was successful, but'
    add = '''#ifdef CONFIG_ESP32C3_GENERIC_WS2812
  ret = board_ws2812_initialize(0, ESPRESSIF_SPI2,
                                CONFIG_ESP32C3_GENERIC_WS2812_NLEDS);
  if (ret < 0)
    {
      syslog(LOG_ERR, "ERROR: board_ws2812_initialize() failed: %d\\n", ret);
    }
#endif

'''
    assert marker in s
    io.open(br, 'w', encoding='utf-8').write(s.replace(marker, add + marker, 1))
    print('  bringup: +ws2812 init')

# 头文件声明
hd = os.path.join(src, 'esp32c3-generic.h')
s = io.open(hd, encoding='utf-8').read()
if 'board_ws2812_initialize' not in s:
    add = ('/* WS2812 (SPI2 based) */\n'
           '#ifdef CONFIG_ESP32C3_GENERIC_WS2812\n'
           'int board_ws2812_initialize(int devno, int spino, uint16_t nleds);\n'
           '#endif\n\n')
    s = s.replace('/* RMT gpio */', add + '/* RMT gpio */', 1)
    io.open(hd, 'w', encoding='utf-8').write(s)
    print('  header: +prototype')
PYEOF

#----------------------------------------------------------------------------
echo "[2b/9] bringup : BLE 初始化失败不中断后续初始化"
# esp_bringup() 是在 NSH 启动时经 boardctl(BOARDIOC_INIT) 调用的
# （CONFIG_BOARD_LATE_INITIALIZE 未开）。若 BLE 初始化失败就 return，
# 后面的 WS2812 注册/自动广播都会被跳过，排障时连灯带自检都用不了。
python3 - "$V/nuttx/boards/risc-v/esp32c3/esp32c3-generic/src/esp32c3_bringup.c" <<'PYEOF'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
if 'BTSH_BLE_NONFATAL' in s:
    print('  skip')
    sys.exit(0)

old = '''      syslog(LOG_ERR, "ERROR: Failed to initialize BLE\\n");
      return ret;'''
new = '''      /* BTSH_BLE_NONFATAL: 不要让 BLE 失败挡住后面的初始化。 */

      syslog(LOG_ERR, "ERROR: Failed to initialize BLE: %d (continue)\\n",
             ret);
      ret = OK;'''
assert old in s, 'BLE init block not found'
s = s.replace(old, new, 1)
io.open(p, 'w', encoding='utf-8').write(s)
print('  +BLE non-fatal')
PYEOF

#----------------------------------------------------------------------------
echo "[2c/9] 板级 : BLE 开机自动广播（btlight-auto 变体用）"
python3 - "$BOARD/Kconfig" "$BOARD/src/esp32c3_bringup.c" \
          "$BOARD/src/esp32c3-generic.h" <<'PYEOF'
import io, sys
kcfg, br, hdr = sys.argv[1], sys.argv[2], sys.argv[3]

# ---- 板级 Kconfig ----
s = io.open(kcfg, encoding='utf-8').read()
if 'ESP32C3_GENERIC_BTSH_AUTOSTART' not in s:
    add = '''
config ESP32C3_GENERIC_BTSH_AUTOSTART
\tbool "Auto-start BLE advertising at boot"
\tdefault n
\tdepends on BTSH_LIGHT
\t---help---
\t\tSpawn "btsh_light start" automatically during bring-up so the board
\t\tadvertises as BTSH-LIGHT without needing an NSH session.

if ESP32C3_GENERIC_BTSH_AUTOSTART

config ESP32C3_GENERIC_BTSH_AUTOSTART_DELAY
\tint "Delay before auto-start (ms)"
\tdefault 3000
\trange 0 60000

config ESP32C3_GENERIC_BTSH_AUTOSTART_PRIORITY
\tint "Auto-start task priority"
\tdefault 100

config ESP32C3_GENERIC_BTSH_AUTOSTART_STACKSIZE
\tint "Auto-start task stack size"
\tdefault 4096

endif # ESP32C3_GENERIC_BTSH_AUTOSTART

'''
    assert 'endif # ESP32C3_GENERIC_WS2812' in s, 'WS2812 endif anchor not found'
    s = s.replace('endif # ESP32C3_GENERIC_WS2812',
                  'endif # ESP32C3_GENERIC_WS2812\n' + add, 1)
    io.open(kcfg, 'w', encoding='utf-8').write(s)
    print('  Kconfig: +AUTOSTART')

# ---- 头文件声明 ----
s = io.open(hdr, encoding='utf-8').read()
if 'CONFIG_ESP32C3_GENERIC_BTSH_AUTOSTART' not in s:
    add = '''
/* BLE autostart */

#ifdef CONFIG_ESP32C3_GENERIC_BTSH_AUTOSTART
extern int btsh_light_main(int argc, char *argv[]);
#endif
'''
    assert '/* RMT gpio */' in s
    s = s.replace('/* RMT gpio */', add + '\n/* RMT gpio */', 1)
    io.open(hdr, 'w', encoding='utf-8').write(s)
    print('  header: +btsh_light_main')

# ---- bringup ----
s = io.open(br, encoding='utf-8').read()
if 'esp32c3_btsh_autostart' not in s:
    if '#include <nuttx/kthread.h>' not in s:
        assert '#include <nuttx/fs/fs.h>' in s
        s = s.replace('#include <nuttx/fs/fs.h>',
                      '#include <nuttx/fs/fs.h>\n#include <nuttx/kthread.h>', 1)

    func = '''/****************************************************************************
 * Private Functions
 ****************************************************************************/

#ifdef CONFIG_ESP32C3_GENERIC_BTSH_AUTOSTART
static int esp32c3_btsh_autostart(int argc, FAR char *argv[])
{
  char *args[3];

  /* Give BT/GATT a moment to settle before advertising */

  usleep(CONFIG_ESP32C3_GENERIC_BTSH_AUTOSTART_DELAY * 1000);

  args[0] = (char *)"btsh_light";
  args[1] = (char *)"start";
  args[2] = NULL;

  syslog(LOG_INFO, "BTSH: autostart advertising\\n");
  return btsh_light_main(2, args);
}
#endif

'''
    marker = ('/****************************************************************************\n'
              ' * Public Functions\n'
              ' ****************************************************************************/')
    assert marker in s
    s = s.replace(marker, func + marker, 1)

    tail_marker = '  /* If we got here then perhaps not all initialization was successful, but'
    add = '''#ifdef CONFIG_ESP32C3_GENERIC_BTSH_AUTOSTART
  /* Start BLE advertising automatically */

  ret = kthread_create("btsh_auto",
                       CONFIG_ESP32C3_GENERIC_BTSH_AUTOSTART_PRIORITY,
                       CONFIG_ESP32C3_GENERIC_BTSH_AUTOSTART_STACKSIZE,
                       esp32c3_btsh_autostart, NULL);
  if (ret < 0)
    {
      syslog(LOG_ERR, "ERROR: btsh autostart task failed: %d\\n", ret);
    }
#endif

'''
    assert tail_marker in s
    s = s.replace(tail_marker, add + tail_marker, 1)
    io.open(br, 'w', encoding='utf-8').write(s)
    print('  bringup: +autostart task')
PYEOF

#----------------------------------------------------------------------------
echo "[3/9] Kconfig：不需要任何修改（重要）"
cat <<'EOF'
  openvela 用的是 Python kconfiglib（prebuilts/tools/python/dist-packages/kconfiglib），
  它**原生支持** osource / orsource 以及 ---help-- / --help-- 这些写法。

  ⚠️ 请勿对树里的 Kconfig 做 "osource -> source" 或 "--help-- -> ---help---" 之类的
     批量替换：那会破坏 if/endif 配对（有些 endif 在被包含的文件里），
     导致 olddefconfig 失败。若已误改，用 git checkout 还原：
         git -C ~/openvela/nuttx        checkout -- $(git -C ~/openvela/nuttx diff --name-only | grep -i kconfig)
         git -C ~/openvela/external/zblue/zblue checkout -- .
EOF

#----------------------------------------------------------------------------
echo "[4/9] riscv_mtimer.c 排除（C3 不用机器定时器）"
python3 - "$N/arch/risc-v/src/common/Make.defs" <<'PYEOF'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
if 'ESP32C3_SKIP_MTIMER' not in s:
    old = 'CMN_CSRCS += riscv_initialize.c riscv_swint.c riscv_mtimer.c'
    new = ('CMN_CSRCS += riscv_initialize.c riscv_swint.c\n\n'
           '# ESP32C3_SKIP_MTIMER: C3 uses esp_timer/esp_oneshot and never calls\n'
           '# riscv_mtimer_initialize().\n\n'
           'ifneq ($(CONFIG_ARCH_CHIP_ESP32C3_GENERIC),y)\n'
           'CMN_CSRCS += riscv_mtimer.c\nendif')
    assert old in s
    io.open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
    print('  patched')
else:
    print('  skip')
PYEOF

#----------------------------------------------------------------------------
echo "[5/9] esp-hal clk_ctrl_os.c : spinlock_t 初值"
F="$CHIP/esp-hal-3rdparty/components/esp_hw_support/clk_ctrl_os.c"
if [ -f "$F" ]; then
  sed -i -E 's|^#define LOCK_INITIALIZER_UNLOCKED.*$|#define LOCK_INITIALIZER_UNLOCKED       {}|' "$F"
  echo "  patched"
else
  echo "  WARN: esp-hal 未准备好（先跑一次编译让它就位）"
fi

#----------------------------------------------------------------------------
echo "[6/9] esp_ble_adapter.c / esp_wireless.c API 修复"
python3 - "$CHIP" <<'PYEOF'
import io, os, sys
chip = sys.argv[1]

p = os.path.join(chip, 'esp_ble_adapter.c')
s = io.open(p, encoding='utf-8').read()
if '(unsigned long)MSEC2TICK' not in s:
    s = s.replace('            MSEC2TICK(block_time_ms), ret);',
                  '            (unsigned long)MSEC2TICK(block_time_ms), ret);', 1)
    io.open(p, 'w', encoding='utf-8').write(s)
    print('  esp_ble_adapter.c: cast MSEC2TICK')
else:
    print('  esp_ble_adapter.c: skip')

p = os.path.join(chip, 'esp_wireless.c')
s = io.open(p, encoding='utf-8').read()
need = []
for h in ('nuttx/semaphore.h', 'nuttx/irq.h', 'nuttx/spinlock.h'):
    if h not in s:
        need.append(h)
if need:
    add = ''.join('#include <%s>\n' % h for h in need)
    s = s.replace('#include <nuttx/mqueue.h>', '#include <nuttx/mqueue.h>\n' + add, 1)
    io.open(p, 'w', encoding='utf-8').write(s)
    print('  esp_wireless.c: +' + ', '.join(need))
else:
    print('  esp_wireless.c: skip')
PYEOF

#----------------------------------------------------------------------------
echo "[7/9] esp_libc_stubs.c : __assert_func noreturn"
python3 - "$N/arch/risc-v/src/common/espressif/esp_libc_stubs.c" <<'PYEOF'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
if 'ESP32C3_NORETURN_FIX' not in s:
    old = '  __assert(file, line, expr);\n}'
    new = ('  __assert(file, line, expr);\n\n'
           '  /* ESP32C3_NORETURN_FIX: must not fall through (GCC>=13 + -Werror) */\n'
           '  for (; ; );\n}')
    assert old in s, 'pattern not found'
    io.open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
    print('  patched')
else:
    print('  skip')
PYEOF

#----------------------------------------------------------------------------
echo "[8/9] btsh_light : 广播 API 声明 + 去掉未用 CCC 变量"
python3 - "$V/apps/wireless/bluetooth/btsh_light/btsh_light_main.c" <<'PYEOF'
import io, re, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
changed = []
if 'BTSH_EXTERN_ADV_API' not in s:
    anchor = '#include <nuttx/wireless/bluetooth/bt_core.h>'
    add = anchor + '''

/* BTSH_EXTERN_ADV_API: implemented in wireless/bluetooth/bt_hcicore.c but
 * not declared in any public header in this tree. */

int bt_start_advertising(uint8_t type, FAR const struct bt_eir_s *ad,
                         FAR const struct bt_eir_s *sd);
int bt_stop_advertising(void);
'''
    assert anchor in s
    s = s.replace(anchor, add, 1); changed.append('extern adv decls')
m = re.search(r'^static struct _bt_gatt_ccc_s g_state_ccc;\n', s, re.M)
if m:
    s = s[:m.start()] + s[m.end():]; changed.append('drop g_state_ccc')
if changed:
    io.open(p, 'w', encoding='utf-8').write(s)
print('  ' + (', '.join(changed) if changed else 'skip'))
PYEOF

#----------------------------------------------------------------------------
echo "[8b/9] btsh_light : 按 ws2812 驱动格式正确驱动 N 颗灯珠"
# 原实现写的是 {uint32_t magic; uint8_t r,g,b;} 结构体（对齐后 8 字节），
# 会被驱动当成 2 颗灯：第 1 颗拿到 0x00AA55，第 2 颗垃圾，其余灯不动。
# 正确格式：每灯一个 32 位字 0x00RRGGBB，偏移 0，长度 N*4。
python3 - "$V/apps/wireless/bluetooth/btsh_light/btsh_light_main.c" \
          "$V/apps/wireless/bluetooth/btsh_light/Kconfig" <<'PYEOF'
import io, re, sys
app, kcfg = sys.argv[1], sys.argv[2]
s = io.open(app, encoding='utf-8').read()

if 'uint32_t px[BTSH_LED_COUNT]' not in s and 'g_px' not in s:
    m = re.search(r'static void btsh_light_apply\(uint8_t state\)\n\{.*?\n\}\n', s, re.S)
    assert m, 'btsh_light_apply not found'
    new = '''static void btsh_light_apply(uint8_t state)
{
  uint32_t px[BTSH_LED_COUNT];
  uint8_t  r;
  uint8_t  g;
  uint8_t  b;
  size_t   i;

  if (g_led_fd < 0)
    {
      return;
    }

  if (state == BTSH_CMD_ON)
    {
      r = 0;
      g = 40;      /* 绿色：开 */
      b = 0;
    }
  else
    {
      r = 0;
      g = 0;
      b = 0;
    }

  /* NuttX ws2812(SPI) 写入格式：每灯一个 32 位字 0x00RRGGBB，
   * 长度须为 4 的整数倍，偏移 0 表示从第 1 颗开始。 */

  for (i = 0; i < BTSH_LED_COUNT; i++)
    {
      px[i] = ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
    }

  if (lseek(g_led_fd, 0, SEEK_SET) < 0)
    {
      syslog(LOG_ERR, "BTSH: lseek failed\\n");
      return;
    }

  if (write(g_led_fd, px, sizeof(px)) < 0)
    {
      syslog(LOG_ERR, "BTSH: ws2812 write failed\\n");
      return;
    }

  syslog(LOG_INFO, "BTSH: %u LED(s) -> %s\\n", (unsigned)BTSH_LED_COUNT,
         state == BTSH_CMD_ON ? "ON" : "OFF");
}
'''
    s = s[:m.start()] + new + s[m.end():]
    print('  apply(): rewritten for N LEDs')

if 'BTSH_LED_COUNT' not in s.split('static void btsh_light_apply')[0]:
    anchor = '#define BTSH_WS2812_MAGIC'
    add = ('/* 灯珠数量（与板级 CONFIG_ESP32C3_GENERIC_WS2812_NLEDS 对应）*/\n\n'
           '#ifndef CONFIG_BTSH_LIGHT_LED_COUNT\n#  define BTSH_LED_COUNT 5\n'
           '#else\n#  define BTSH_LED_COUNT CONFIG_BTSH_LIGHT_LED_COUNT\n#endif\n\n')
    assert anchor in s
    s = s.replace(anchor, add + anchor, 1)
    print('  +BTSH_LED_COUNT')

io.open(app, 'w', encoding='utf-8').write(s)

k = io.open(kcfg, encoding='utf-8').read()
if 'BTSH_LIGHT_LED_COUNT' not in k:
    add = ('config BTSH_LIGHT_LED_COUNT\n'
           '\tint "Number of WS2812B LEDs on the strip"\n'
           '\tdefault 5\n\trange 1 1024\n'
           '\t---help---\n\t\tMust match the board WS2812 LED count.\n\n')
    k = k.replace('config BTSH_LIGHT_ADV_NAME', add + 'config BTSH_LIGHT_ADV_NAME', 1)
    io.open(kcfg, 'w', encoding='utf-8').write(k)
    print('  Kconfig: +BTSH_LIGHT_LED_COUNT')
PYEOF

#----------------------------------------------------------------------------
echo "[8c/9] btsh_light : 增加 test 子命令（不依赖 BLE 的灯带自检）"
python3 - "$V/apps/wireless/bluetooth/btsh_light/btsh_light_main.c" <<'PYEOF'
import io, re, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
if 'btsh_light_selftest' in s:
    print('  skip')
    sys.exit(0)

m = re.search(r'static void btsh_light_apply\(uint8_t state\)\n\{.*?\n\}\n', s, re.S)
assert m, 'btsh_light_apply not found'
new = '''static int btsh_light_set_rgb(uint8_t r, uint8_t g, uint8_t b)
{
  uint32_t px[BTSH_LED_COUNT];
  size_t   i;
  ssize_t  n;

  if (g_led_fd < 0)
    {
      return -ENODEV;
    }

  /* NuttX ws2812(SPI) 写入格式：每灯一个 32 位字 0x00RRGGBB */

  for (i = 0; i < BTSH_LED_COUNT; i++)
    {
      px[i] = ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
    }

  if (lseek(g_led_fd, 0, SEEK_SET) < 0)
    {
      syslog(LOG_ERR, "BTSH: lseek failed\\n");
      return -EIO;
    }

  n = write(g_led_fd, px, sizeof(px));
  if (n < (ssize_t)sizeof(px))
    {
      syslog(LOG_ERR, "BTSH: ws2812 write %d/%u failed\\n",
             (int)n, (unsigned)sizeof(px));
      return -EIO;
    }

  return OK;
}

static void btsh_light_apply(uint8_t state)
{
  if (state == BTSH_CMD_ON)
    {
      btsh_light_set_rgb(0, 40, 0);      /* 绿色：开 */
    }
  else
    {
      btsh_light_set_rgb(0, 0, 0);       /* 熄灭：关 */
    }

  syslog(LOG_INFO, "BTSH: %u LED(s) -> %s\\n", (unsigned)BTSH_LED_COUNT,
         state == BTSH_CMD_ON ? "ON" : "OFF");
}

/* 灯带自检：不依赖 BLE，用来单独验证 SPI + WS2812 硬件链路 */

static void btsh_light_selftest(void)
{
  static const struct
    {
      uint8_t r, g, b;
      FAR const char *name;
    } seq[] =
    {
      { 64,  0,  0, "RED"   },
      {  0, 64,  0, "GREEN" },
      {  0,  0, 64, "BLUE"  },
      { 64, 64, 64, "WHITE" },
    };

  size_t i;
  int    ret = OK;

  printf("WS2812 self-test: %u LED(s) on %s (fd=%d)\\n",
         (unsigned)BTSH_LED_COUNT, CONFIG_BTSH_LIGHT_LED_DEV, g_led_fd);

  if (g_led_fd < 0)
    {
      printf("  ERROR: LED device not open.\\n");
      return;
    }

  for (i = 0; i < sizeof(seq) / sizeof(seq[0]); i++)
    {
      printf("  %s\\n", seq[i].name);
      ret = btsh_light_set_rgb(seq[i].r, seq[i].g, seq[i].b);
      if (ret < 0)
        {
          printf("  ERROR: write failed: %d\\n", ret);
          break;
        }

      usleep(400 * 1000);
    }

  btsh_light_set_rgb(0, 0, 0);
  btsh_light_apply(g_light_state);
  printf("  done%s\\n", ret < 0 ? " (with errors)" : "");
}
'''
s = s[:m.start()] + new + s[m.end():]

s = s.replace('printf("Usage: btsh_light <start|stop|state>\\n");',
              'printf("Usage: btsh_light <start|stop|state|test>\\n");')
s = s.replace('printf("  state  显示灯状态与连接状态\\n");',
              'printf("  state  显示灯状态与连接状态\\n");\n'
              '      printf("  test   灯带自检（R/G/B/W 循环，不需要 BLE）\\n");')
anchor = '  else if (strcmp(argv[1], "state") == 0)'
branch = '''  else if (strcmp(argv[1], "test") == 0)
    {
      btsh_light_selftest();
      return OK;
    }
'''
assert anchor in s
s = s.replace(anchor, branch + anchor, 1)
if '#include <unistd.h>' not in s:
    s = s.replace('#include <stdio.h>', '#include <stdio.h>\n#include <unistd.h>', 1)
io.open(p, 'w', encoding='utf-8').write(s)
print('  +test subcommand')
PYEOF

#----------------------------------------------------------------------------
echo "[8d/9] btsh_light : 断开连接后自动重新广播"
# 控制器在建立连接时会自动停止广播，而协议栈断开后不会恢复：
# 不修的话中心设备连一次再断开，本机就永久不可见，只能重启。
python3 - "$V/apps/wireless/bluetooth/btsh_light/btsh_light_main.c" <<'PYEOF'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
if 'BTSH_CONN_CB_API' in s:
    print('  skip')
    sys.exit(0)

s = s.replace('#include <nuttx/wireless/bluetooth/bt_core.h>',
              '#include <nuttx/wireless/bluetooth/bt_core.h>\n'
              '#include <nuttx/wqueue.h>', 1)

anchor = 'int bt_stop_advertising(void);'
assert anchor in s
s = s.replace(anchor, anchor + '''

/* BTSH_CONN_CB_API: 连接状态回调结构与注册函数在 wireless/bluetooth/
 * bt_hcicore.h（内部头文件，不在 include/ 里），应用侧只能自行声明，
 * 布局必须与内核侧一致。 */

struct bt_conn_s;

struct bt_conn_cb_s
{
  FAR struct bt_conn_cb_s *flink;
  FAR void *context;
  CODE void (*connected)(FAR struct bt_conn_s *conn, FAR void *context);
  CODE void (*disconnected)(FAR struct bt_conn_s *conn, FAR void *context);
};

void bt_conn_cb_register(FAR struct bt_conn_cb_s *cb);''', 1)

anchor = 'static int btsh_light_start(void)'
assert anchor in s
s = s.replace(anchor, '''static bool   g_adv_enabled  = false;
static bool   g_conn_cb_done = false;
static struct work_s         g_readv_work;
static struct bt_conn_cb_s   g_conn_cb;

static void btsh_light_readv_worker(FAR void *arg)
{
  int ret;

  if (!g_adv_enabled)
    {
      return;
    }

  (void)bt_stop_advertising();
  ret = bt_start_advertising(BT_LE_ADV_IND, g_adv_data, g_scan_rsp);
  if (ret < 0)
    {
      syslog(LOG_ERR, "BTSH: re-advertise failed: %d\\n", ret);
    }
  else
    {
      syslog(LOG_INFO, "BTSH: re-advertising after disconnect\\n");
    }
}

static void btsh_light_connected_cb(FAR struct bt_conn_s *conn,
                                    FAR void *context)
{
  syslog(LOG_INFO, "BTSH: central connected\\n");
}

static void btsh_light_disconnected_cb(FAR struct bt_conn_s *conn,
                                       FAR void *context)
{
  /* 内核注释明确要求不可假定本回调的线程上下文 */

  syslog(LOG_INFO, "BTSH: central disconnected\\n");
  (void)work_queue(LPWORK, &g_readv_work, btsh_light_readv_worker, NULL, 0);
}

''' + anchor, 1)

anchor = '  syslog(LOG_INFO, "BTSH: advertising as \\"%s\\"\\n",'
assert anchor in s
s = s.replace(anchor, '''  g_adv_enabled = true;

  if (!g_conn_cb_done)
    {
      g_conn_cb.context      = NULL;
      g_conn_cb.connected    = btsh_light_connected_cb;
      g_conn_cb.disconnected = btsh_light_disconnected_cb;

      /* bt_conn_cb_register() 是头插链表，重复注册会让链表成环 */

      bt_conn_cb_register(&g_conn_cb);
      g_conn_cb_done = true;
    }

''' + anchor, 1)

anchor = 'static int btsh_light_stop(void)\n{\n  (void)bt_stop_advertising();'
assert anchor in s
s = s.replace(anchor,
              'static int btsh_light_stop(void)\n{\n  g_adv_enabled = false;\n'
              '  (void)bt_stop_advertising();', 1)

io.open(p, 'w', encoding='utf-8').write(s)
print('  +disconnect re-advertise')
PYEOF

#----------------------------------------------------------------------------
echo "[8e/9] btsh_light : GATT 服务只注册一次"
# 重复执行 start（或 stop 后再 start）会把同一个服务再插一份到属性表，
# 导致对端看到重复服务、句柄错乱。
python3 - "$V/apps/wireless/bluetooth/btsh_light/btsh_light_main.c" <<'PYEOF'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
if 'g_gatt_registered' in s:
    print('  skip')
    sys.exit(0)

anchor = 'static bool   g_adv_enabled  = false;'
assert anchor in s
s = s.replace(anchor, anchor + '\nstatic bool   g_gatt_registered = false;', 1)

old = '''  bt_gatt_register(g_attrs, nitems(g_attrs));
  syslog(LOG_INFO, "BTSH: GATT service 0x%04x registered (%d attrs)\\n",
         BTSH_UUID_SERVICE, BTSH_ATTR_COUNT);'''
new = '''  /* GATT 服务只能注册一次：重复执行 start（或 stop 后再 start）
   * 会向属性表里再插一份，导致对端看到重复服务/句柄错乱。
   */

  if (!g_gatt_registered)
    {
      bt_gatt_register(g_attrs, nitems(g_attrs));
      g_gatt_registered = true;

      syslog(LOG_INFO, "BTSH: GATT service 0x%04x registered (%d attrs)\\n",
             BTSH_UUID_SERVICE, BTSH_ATTR_COUNT);
    }'''
assert old in s
s = s.replace(old, new, 1)
io.open(p, 'w', encoding='utf-8').write(s)
print('  +single GATT registration')
PYEOF

#----------------------------------------------------------------------------
echo "[8f/9] btsh_light : 逐灯 RGB（0xFF01 写 4 字节，向后兼容）"
#   1 字节 -> 开/关（旧协议不变）
#   4 字节 -> [index, R, G, B]，index 0xFF = 全部
python3 - "$V/apps/wireless/bluetooth/btsh_light/btsh_light_main.c" <<'PYEOF'
import io, re, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
if 'g_px' in s:
    print('  skip')
    sys.exit(0)

anchor = '#define BTSH_CMD_ON        0x01'
assert anchor in s
s = s.replace(anchor, anchor + '''

/* 4 字节 RGB 写入时的 index 特殊值：整条灯带 */

#define BTSH_RGB_ALL       0xff''', 1)

anchor = 'static uint8_t g_light_state = BTSH_CMD_OFF;'
assert anchor in s
s = s.replace(anchor, anchor + '''

/* 每颗灯的当前颜色（0x00RRGGBB），作为唯一真源 */

static uint32_t g_px[BTSH_LED_COUNT];''', 1)

m = re.search(r'static int btsh_light_set_rgb\(uint8_t r, uint8_t g, uint8_t b\)\n\{.*?\n\}\n', s, re.S)
assert m
s = s[:m.start()] + '''static uint32_t btsh_rgb(uint8_t r, uint8_t g, uint8_t b)
{
  return ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
}

static int btsh_light_flush(void)
{
  ssize_t n;

  if (g_led_fd < 0)
    {
      return -ENODEV;
    }

  if (lseek(g_led_fd, 0, SEEK_SET) < 0)
    {
      syslog(LOG_ERR, "BTSH: lseek failed\\n");
      return -EIO;
    }

  n = write(g_led_fd, g_px, sizeof(g_px));
  if (n < (ssize_t)sizeof(g_px))
    {
      syslog(LOG_ERR, "BTSH: ws2812 write %d/%u failed\\n",
             (int)n, (unsigned)sizeof(g_px));
      return -EIO;
    }

  return OK;
}

static int btsh_light_set_all(uint8_t r, uint8_t g, uint8_t b)
{
  size_t i;

  for (i = 0; i < BTSH_LED_COUNT; i++)
    {
      g_px[i] = btsh_rgb(r, g, b);
    }

  return btsh_light_flush();
}

static int btsh_light_set_one(size_t idx, uint8_t r, uint8_t g, uint8_t b)
{
  if (idx >= BTSH_LED_COUNT)
    {
      return -EINVAL;
    }

  g_px[idx] = btsh_rgb(r, g, b);
  return btsh_light_flush();
}

static int btsh_light_set_rgb(uint8_t r, uint8_t g, uint8_t b)
{
  return btsh_light_set_all(r, g, b);
}

static uint8_t btsh_light_aggregate(void)
{
  size_t i;

  for (i = 0; i < BTSH_LED_COUNT; i++)
    {
      if ((g_px[i] & 0x00ffffff) != 0)
        {
          return BTSH_CMD_ON;
        }
    }

  return BTSH_CMD_OFF;
}
''' + s[m.end():]

m = re.search(r'static int btsh_write_cmd\(FAR struct bt_conn_s \*conn,\n(?:.*?\n)*?\}\n', s)
assert m
s = s[:m.start()] + '''static int btsh_write_cmd(FAR struct bt_conn_s *conn,
                          FAR const struct bt_gatt_attr_s *attr,
                          FAR const void *buf, uint8_t len, uint16_t offset)
{
  FAR const uint8_t *cmd = (FAR const uint8_t *)buf;
  uint8_t newstate;
  int     ret;

  UNUSED(attr);
  UNUSED(conn);

  if (len < 1 || offset != 0)
    {
      syslog(LOG_ERR, "BTSH: bad cmd (len=%u offset=%u)\\n", (unsigned)len,
             (unsigned)offset);
      return -EINVAL;
    }

  /* 4 字节：[index, R, G, B]；index 0xFF = 全部 */

  if (len == 4)
    {
      uint8_t idx = cmd[0];

      if (idx == BTSH_RGB_ALL)
        {
          ret = btsh_light_set_all(cmd[1], cmd[2], cmd[3]);
        }
      else
        {
          ret = btsh_light_set_one(idx, cmd[1], cmd[2], cmd[3]);
        }

      if (ret < 0)
        {
          syslog(LOG_ERR, "BTSH: rgb write failed: %d\\n", ret);
          return ret;
        }

      syslog(LOG_INFO, "BTSH: rgb[%u] = %02x %02x %02x\\n",
             (unsigned)idx, cmd[1], cmd[2], cmd[3]);

      newstate = btsh_light_aggregate();
      if (newstate != g_light_state)
        {
          g_light_state = newstate;
          bt_gatt_notify(BTSH_STATE_VAL_HANDLE, &g_light_state,
                         sizeof(g_light_state));
        }

      return OK;
    }

  if (len != 1)
    {
      syslog(LOG_ERR, "BTSH: unsupported cmd length %u\\n", (unsigned)len);
      return -EINVAL;
    }

  if (cmd[0] != BTSH_CMD_OFF && cmd[0] != BTSH_CMD_ON)
    {
      syslog(LOG_ERR, "BTSH: unknown cmd 0x%02x\\n", cmd[0]);
      return -EINVAL;
    }

  newstate = (cmd[0] == BTSH_CMD_ON) ? BTSH_CMD_ON : BTSH_CMD_OFF;

  if (newstate != g_light_state)
    {
      g_light_state = newstate;
      btsh_light_apply(g_light_state);
      bt_gatt_notify(BTSH_STATE_VAL_HANDLE, &g_light_state,
                     sizeof(g_light_state));
    }

  return OK;
}
''' + s[m.end():]

io.open(p, 'w', encoding='utf-8').write(s)
print('  +per-LED RGB')
PYEOF

# 8f 收尾：无条件保证 apply() 走 g_px 真源。
# 8b 有可能在 8f 之后被再次触发（它的守卫看 px[]，而 8f 用的是 g_px[]），
# 这里做一次幂等校正，避免 apply() 绕过影子数组导致颜色被覆盖。
python3 - "$V/apps/wireless/bluetooth/btsh_light/btsh_light_main.c" <<'PYEOF'
import io, re, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
m = re.search(r'static void btsh_light_apply\(uint8_t state\)\n\{.*?\n\}\n', s, re.S)
assert m, 'btsh_light_apply not found'
if 'btsh_light_set_all' in m.group(0):
    print('  apply() 已是 set_all 版，skip')
else:
    s = s[:m.start()] + '''static void btsh_light_apply(uint8_t state)
{
  if (state == BTSH_CMD_ON)
    {
      btsh_light_set_all(0, 40, 0);      /* 绿色：开 */
    }
  else
    {
      btsh_light_set_all(0, 0, 0);       /* 熄灭：关 */
    }

  syslog(LOG_INFO, "BTSH: %u LED(s) -> %s\\n", (unsigned)BTSH_LED_COUNT,
         state == BTSH_CMD_ON ? "ON" : "OFF");
}
''' + s[m.end():]
    io.open(p, 'w', encoding='utf-8').write(s)
    print('  apply() -> set_all 版')
PYEOF

#----------------------------------------------------------------------------
echo "[9/9] 完成。构建命令："
cat <<'EOF'

  export PATH=$HOME/openvela/prebuilts/build-tools/linux-x86_64/bin:$HOME/.local/bin:$HOME/tc-bin:$HOME/riscv32-esp-elf/bin:$PATH
  export CROSSDEV=riscv64-unknown-elf-
  export CONFIG_STACK_USAGE_WARNING=0

  # 首次/config 变更后（官方 build.sh 路径）：
  cd ~/openvela && ./build.sh vendor/espressif/boards/esp32c3/esp32c3-generic/configs/btlight/ -j20

  # 之后增量编译（绕开 unionfs，更快）：
  cd ~/openvela/nuttx && make -j20 EXTRAFLAGS="-Wno-cpp -Wno-deprecated-declarations"

  产物：nuttex/nuttx（ELF）、nuttx/nuttx.bin（烧录镜像）
EOF

if [ "$1" = "--build" ]; then
  echo
  echo "=== building ==="
  cd "$V"
  export PATH="$V/prebuilts/build-tools/linux-x86_64/bin:$HOME/.local/bin:$HOME/tc-bin:$HOME/riscv32-esp-elf/bin:$PATH"
  export CROSSDEV=riscv64-unknown-elf-
  export CONFIG_STACK_USAGE_WARNING=0
  ./build.sh vendor/espressif/boards/esp32c3/esp32c3-generic/configs/btlight/ -j20
fi
