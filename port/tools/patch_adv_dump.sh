#!/usr/bin/env bash
# 诊断工具：在协议栈里打印"实际发给控制器的广播字节"
#
# 用途：确认广播内容与固件预期一致（排查"中心设备看不到厂商数据"）。
# 注意：wlerr 受 CONFIG_DEBUG_WIRELESS_ERROR 控制，默认编译成空宏，
#       所以这里用 syslog(LOG_ERR) 直接输出，不受调试开关影响。
#
# 用法：
#   bash port/tools/patch_adv_dump.sh          # 打补丁
#   ./build.sh vendor/espressif/boards/esp32c3/esp32c3-generic/configs/advdiag/ -j20
#   # 串口会看到 BTSH_ADV_DUMP: adv len=.. [..]  /  rsp len=.. [..]
#   git -C ~/openvela/nuttx checkout -- wireless/bluetooth/bt_hcicore.c   # 还原
set -u
F=${VELA_ROOT:-$HOME/openvela}/nuttx/wireless/bluetooth/bt_hcicore.c

python3 - "$F" <<'PYEOF'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
if 'BTSH_ADV_DUMP' in s:
    print('已打过补丁'); sys.exit(0)

if '#include <syslog.h>' not in s:
    s = s.replace('#include <string.h>', '#include <string.h>\n#include <syslog.h>', 1)

def dump(var):
    return '''  {
    char dump[128];
    int off = 0;
    int k;

    off += snprintf(dump + off, sizeof(dump) - off,
                    "BTSH_ADV_DUMP: %s len=%%u [", %s->len);
    for (k = 0; k < %s->len && off < (int)sizeof(dump) - 4; k++)
      {
        off += snprintf(dump + off, sizeof(dump) - off, "%%02x", %s->data[k]);
      }

    snprintf(dump + off, sizeof(dump) - off, "]");
    syslog(LOG_ERR, "%%s\\\\n", dump);
  }

''' % ('adv' if var == 'set_data' else 'rsp', var, var, var)

s = s.replace('  bt_hci_cmd_send(BT_HCI_OP_LE_SET_ADV_DATA, buf);',
              dump('set_data') + '  bt_hci_cmd_send(BT_HCI_OP_LE_SET_ADV_DATA, buf);', 1)
s = s.replace('  bt_hci_cmd_send(BT_HCI_OP_LE_SET_SCAN_RSP_DATA, buf);',
              dump('scan_rsp') + '  bt_hci_cmd_send(BT_HCI_OP_LE_SET_SCAN_RSP_DATA, buf);', 1)
io.open(p, 'w', encoding='utf-8').write(s)
print('已注入 BTSH_ADV_DUMP')
PYEOF
