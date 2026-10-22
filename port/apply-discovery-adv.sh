#!/usr/bin/env bash
#============================================================================
# v1.1 功能：广播能力声明（免连接识别）
#
# 在 BLE 广播数据（ADV_IND）里加入 Manufacturer Specific Data，
# 让中心设备不建立连接就能识别设备类型、灯珠数量与支持的能力。
#
# 效果等价于官方宣传的"设备间无缝发现"，但完全基于标准 BLE 广播，
# 不依赖任何私有协议。
#
# 幂等，可重复执行。
#============================================================================
set -u
V=${VELA_ROOT:-$HOME/openvela}
A=$V/apps/wireless/bluetooth/btsh_light/btsh_light_main.c

echo "=============================================="
echo " v1.1 广播能力声明（免连接识别）"
echo "=============================================="

if [ ! -f "$A" ]; then
  echo "  !! 找不到 $A"
  echo "     请先执行 port/apply-all.sh"
  exit 1
fi

python3 - "$A" <<'PYEOF'
import io, sys

p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()

if 'BTSH_DISCOVERY_ADV' in s:
    print('  已打过补丁，跳过')
    sys.exit(0)

n = 0

# ------------------------------------------------------------------ 常量定义
old = '''#ifndef CONFIG_BTSH_LIGHT_ADV_NAME
#  define CONFIG_BTSH_LIGHT_ADV_NAME "BTSH-LIGHT"
#endif'''
new = '''#ifndef CONFIG_BTSH_LIGHT_ADV_NAME
#  define CONFIG_BTSH_LIGHT_ADV_NAME "BTSH-LIGHT"
#endif

/* BTSH_DISCOVERY_ADV —— 广播里的"能力声明"
 *
 * 目的：让中心设备（A7Z）**不用连接**就知道对端是什么、能做什么，
 *       实现"扫到即识别、免配置连接"的体验。
 *
 * 载荷布局（6 字节，放在 Manufacturer Specific Data 里）：
 *   [0..1] Company ID  = 0xFFFF（小端）
 *          ★ BT SIG 保留给测试/开发用途；量产必须申请正式 Company ID
 *   [2]    协议版本    = 1
 *   [3]    设备类型    = 1（RGB 灯控）
 *   [4]    灯珠数量    = CONFIG_BTSH_LIGHT_LED_COUNT
 *   [5]    能力位      = 0x07
 *            bit0  支持 1 字节开关
 *            bit1  支持 4 字节逐灯 RGB
 *            bit2  支持状态通知
 */

#define BTSH_DISC_COMPANY_ID_LO   0xff
#define BTSH_DISC_COMPANY_ID_HI   0xff
#define BTSH_DISC_VER             1
#define BTSH_DISC_DEVTYPE_LIGHT   1
#define BTSH_DISC_CAPS            0x07
#define BTSH_DISC_LEN             6      /* 上面 6 个字节 */'''
assert old in s, '广播名默认值锚点没找到'
s = s.replace(old, new, 1); n += 1

# ------------------------------------------------------------------ 数组扩容
old = '''static struct bt_eir_s g_adv_data[2];
static struct bt_eir_s g_scan_rsp[2];'''
new = '''static struct bt_eir_s g_adv_data[3];   /* flags + 厂商数据 + 终止项 */
static struct bt_eir_s g_scan_rsp[2];'''
assert old in s, 'g_adv_data 定义没找到'
s = s.replace(old, new, 1); n += 1

# ------------------------------------------------------------------ 填装数据
old = '''  g_adv_data[0].len     = 2;
  g_adv_data[0].type    = BT_EIR_FLAGS;
  g_adv_data[0].data[0] = BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR;
  g_adv_data[1].len     = 0;
  g_adv_data[1].type    = 0;'''
new = '''  g_adv_data[0].len     = 2;
  g_adv_data[0].type    = BT_EIR_FLAGS;
  g_adv_data[0].data[0] = BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR;

  /* 厂商自定义数据：不连接即可识别设备类型与能力
   *
   * ★ len 的语义：EIR 长度字段 = 1(type) + 数据字节数。
   *   协议栈内部 memcpy 拷 len+1 字节（其中最后一条是 type），
   *   所以 6 字节数据必须写 len = 7。写错会导致整条广播失效。
   */

  g_adv_data[1].len     = 1 + BTSH_DISC_LEN;
  g_adv_data[1].type    = BT_EIR_MANUFACTURER_DATA;
  g_adv_data[1].data[0] = BTSH_DISC_COMPANY_ID_LO;
  g_adv_data[1].data[1] = BTSH_DISC_COMPANY_ID_HI;
  g_adv_data[1].data[2] = BTSH_DISC_VER;
  g_adv_data[1].data[3] = BTSH_DISC_DEVTYPE_LIGHT;
  g_adv_data[1].data[4] = CONFIG_BTSH_LIGHT_LED_COUNT;
  g_adv_data[1].data[5] = BTSH_DISC_CAPS;

  g_adv_data[2].len     = 0;
  g_adv_data[2].type    = 0;'''
assert old in s, '广播数据填装代码没找到'
s = s.replace(old, new, 1); n += 1

# ------------------------------------------------------------------ 日志
old = '''         CONFIG_BTSH_LIGHT_ADV_NAME);'''
new = '''         CONFIG_BTSH_LIGHT_ADV_NAME);

  /* 打印广播里的能力声明，便于现场核对中心设备扫描到的内容 */

  syslog(LOG_INFO,
         "BTSH: discovery adv: company=0x%02x%02x ver=%d type=%d leds=%d caps=0x%02x\\n",
         BTSH_DISC_COMPANY_ID_HI, BTSH_DISC_COMPANY_ID_LO,
         BTSH_DISC_VER, BTSH_DISC_DEVTYPE_LIGHT,
         CONFIG_BTSH_LIGHT_LED_COUNT, BTSH_DISC_CAPS);'''
if 'BTSH: discovery adv' not in s:
    assert old in s, '广播日志锚点没找到'
    s = s.replace(old, new, 1); n += 1

io.open(p, 'w', encoding='utf-8').write(s)
print('  patched:', n, '处')
PYEOF

echo
echo "完成。重新编译即可生效："
echo "  ./build.sh vendor/espressif/boards/esp32c3/esp32c3-generic/configs/production/ -j20"
