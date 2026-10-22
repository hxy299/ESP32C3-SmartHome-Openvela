#!/usr/bin/env bash
#============================================================================
# ESP32-C3 现场调试发现的协议栈修复（三个 bug）
#
# 这三个问题只有在真实硬件 + 真实 BLE 客户端交互时才会暴露，
# 静态检查完全看不出来。幂等，可重复执行。
#
#   1. bt_att.c : hdr->code 悬垂指针
#        症状：能连上、ATT 请求能收到，但永不应答（服务发现失败）
#   2. bt_gatt.c : gatt_ccc_changed() 调用 cfg_changed 没有 NULL 检查
#        症状：客户端一开启 NOTIFY 就 Instruction access fault (EPC=0) 崩溃
#        配合：应用必须给 BT_GATT_CCC 传真实回调，不能传 NULL
#   3. 配置：控制器→主机流控必须关闭，否则 ACL 数据永远下不来
#        症状：连接建立成功，但对端的数据一个字节都收不到
#============================================================================
set -u
V=${VELA_ROOT:-$HOME/openvela}
N=$V/nuttx
APP=$V/apps/wireless/bluetooth/btsh_light/btsh_light_main.c
ATT=$N/wireless/bluetooth/bt_att.c
GATT=$N/wireless/bluetooth/bt_gatt.c

echo "=============================================="
echo " 协议栈修复（现场调试所得）"
echo "=============================================="

#----------------------------------------------------------------------------
echo "[1/7] bt_att.c : 先保存 opcode 再 consume"
python3 - "$ATT" <<'PYEOF'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
if 'BTSH_ATT_CODE_FIX' in s:
    print('  skip'); sys.exit(0)

old = '''  bt_buf_consume(buf, sizeof(*hdr));

  for (i = 0; i < NHANDLERS; i++)
    {
      if (hdr->code != g_handlers[i].op)
        {
          continue;
        }

      if (buf->len < g_handlers[i].expect_len)
        {
          wlerr("ERROR: Invalid len %u for code 0x%02x\\n",
                buf->len, hdr->code);
          err = BT_ATT_ERR_INVALID_PDU;
          break;
        }

      err = g_handlers[i].func(conn, buf);
      break;
    }'''
new = '''  /* BTSH_ATT_CODE_FIX: hdr 指向 buf->data，bt_buf_consume() 之后该内存
   * 可能被复用。原代码查表时仍用 hdr->code，被改写后匹配不到处理函数，
   * 于是所有 ATT 请求都被当成"不支持"静默丢弃（能连上但服务发现失败）。
   */

  code = hdr->code;
  bt_buf_consume(buf, sizeof(*hdr));

  for (i = 0; i < NHANDLERS; i++)
    {
      if (code != g_handlers[i].op)
        {
          continue;
        }

      if (buf->len < g_handlers[i].expect_len)
        {
          wlerr("ERROR: Invalid len %u for code 0x%02x\\n", buf->len, code);
          err = BT_ATT_ERR_INVALID_PDU;
          break;
        }

      err = g_handlers[i].func(conn, buf);
      break;
    }'''
old2 = '''  FAR struct bt_att_hdr_s *hdr = (FAR void *)buf->data;
  uint8_t err = BT_ATT_ERR_NOT_SUPPORTED;
  size_t i;'''
new2 = '''  FAR struct bt_att_hdr_s *hdr = (FAR void *)buf->data;
  uint8_t err = BT_ATT_ERR_NOT_SUPPORTED;
  uint8_t code;
  size_t i;'''
assert old in s and old2 in s, 'bt_att.c 锚点没找到'
s = s.replace(old, new, 1).replace(old2, new2, 1)
io.open(p, 'w', encoding='utf-8').write(s)
print('  patched')
PYEOF

#----------------------------------------------------------------------------
echo "[2/7] bt_gatt.c : gatt_ccc_changed 的 NULL 保护"
python3 - "$GATT" <<'PYEOF'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
if 'BTSH_CCC_NULLGUARD' in s:
    print('  skip'); sys.exit(0)

old = '''      ccc->value = value;
      ccc->cfg_changed(value);'''
new = '''      ccc->value = value;

      /* BTSH_CCC_NULLGUARD: BT_GATT_CCC 的第 4 个参数允许为 NULL，
       * 这里必须检查，否则客户端写 CCC 时会调用空指针，
       * 导致 Instruction access fault (EPC=00000000) 整机 PANIC。
       */

      if (ccc->cfg_changed != NULL)
        {
          ccc->cfg_changed(value);
        }'''
assert old in s, 'bt_gatt.c 锚点没找到'
s = s.replace(old, new, 1)
io.open(p, 'w', encoding='utf-8').write(s)
print('  patched')
PYEOF

#----------------------------------------------------------------------------
echo "[3/7] 应用 : CCC 传真实回调（不能传 NULL）"
python3 - "$APP" <<'PYEOF'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
if 'btsh_ccc_changed' in s:
    print('  skip'); sys.exit(0)

anchor = 'static const struct bt_gatt_attr_s g_attrs[] ='
add = '''/****************************************************************************
 * Name: btsh_ccc_changed
 *
 * Description:
 *   CCC（客户端特征配置）变化回调。
 *
 *   ★ 必须传真实函数，不能给 BT_GATT_CCC 传 NULL：调用链
 *     bt_gatt_attr_write_ccc() -> gatt_ccc_changed() -> ccc->cfg_changed()
 *     在旧版协议栈里没有 NULL 检查，传 NULL 会导致客户端一开通知就
 *     跳到地址 0（Instruction access fault / EPC=00000000）整机 PANIC。
 *
 ****************************************************************************/

static void btsh_ccc_changed(uint16_t value)
{
  syslog(LOG_INFO, "BTSH: CCC changed -> 0x%04x\\n", value);
}

'''
assert anchor in s
s = s.replace(anchor, add + anchor, 1)

old = '''  BT_GATT_CCC(BTSH_STATE_CCC_HANDLE, BTSH_STATE_VAL_HANDLE,
              g_state_ccc_cfg, NULL),'''
new = '''  BT_GATT_CCC(BTSH_STATE_CCC_HANDLE, BTSH_STATE_VAL_HANDLE,
              g_state_ccc_cfg, btsh_ccc_changed),'''
assert old in s, 'BT_GATT_CCC 调用没找到'
s = s.replace(old, new, 1)
io.open(p, 'w', encoding='utf-8').write(s)
print('  patched')
PYEOF

#----------------------------------------------------------------------------
echo "[4/7] bt_att.c : MTU 请求钳位（不要拒绝）"
python3 - "$ATT" <<'PYEOF_INNER'
import io, re, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
if 'BTSH_MTU_CLAMP' in s:
    print('  skip'); sys.exit(0)

m = re.search(
    r'  mtu = BT_LE162HOST\(req->mtu\);\s*\n\s*\n(\s*)(?:wlinfo\("Client MTU[^\n]*\n\s*\n)?'
    r'\s*if \(mtu > BT_ATT_MAX_LE_MTU \|\| mtu < BT_ATT_DEFAULT_LE_MTU\)\s*\n\s*\{\s*\n'
    r'\s*return BT_ATT_ERR_INVALID_PDU;\s*\n\s*\}', s)
assert m, 'att_mtu_req 里的范围检查没找到'

repl = '''  mtu = BT_LE162HOST(req->mtu);

  /* BTSH_MTU_CLAMP: 超出范围的 MTU 请求要**钳位**，不能直接拒绝。
   *
   * 原实现遇到 mtu > 517 或 < 23 就 return BT_ATT_ERR_INVALID_PDU。
   * Windows(WinRT) 实际请求 527，于是被拒；中心设备拿不到 MTU 响应就
   * 不敢继续做服务发现，表现为 connect() 30 秒超时。Android(nRF Connect)
   * 恰好请求合法值，所以同一个固件在手机上正常 —— 极难排查。
   *
   * 按 BLE 规范，服务器应在响应里给出自己支持的 MTU，请求过大时回一个小值。
   */

  syslog(LOG_INFO, "BTSH: MTU req=%u\\n", mtu);

  if (mtu < BT_ATT_DEFAULT_LE_MTU)
    {
      mtu = BT_ATT_DEFAULT_LE_MTU;
    }
  else if (mtu > BT_ATT_MAX_LE_MTU)
    {
      mtu = BT_ATT_MAX_LE_MTU;
    }'''

s = s[:m.start()] + repl + s[m.end():]

if '#include <syslog.h>' not in s:
    s = s.replace('#include <string.h>', '#include <string.h>\n#include <syslog.h>', 1)

io.open(p, 'w', encoding='utf-8').write(s)
print('  patched')
PYEOF_INNER

#----------------------------------------------------------------------------
echo "[5/7] 应用 : GATT 写回调返回 len（不是 OK）"
python3 - "$APP" <<'PYEOF_INNER2'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
if 'BTSH_WRITE_RET_LEN' in s:
    print('  skip'); sys.exit(0)

start = s.index('static int btsh_write_cmd(FAR struct bt_conn_s *conn,')
end = s.index('static void btsh_light_connected_cb', start)
body = s[start:end]

new_body = body.replace('  return OK;\n', '''  /* BTSH_WRITE_RET_LEN: GATT 写回调必须返回**写入的字节数**。
   *
   * 协议栈 bt_att.c 的 write_cb：
   *     write = attr->write(...);
   *     if (write < 0 || write != data->len) { data->err = err_to_att(write); ... }
   *
   * 返回 OK(0) 时 len=1 -> 0 != 1 成立 -> err_to_att(0) 落到 default ->
   * BT_ATT_ERR_UNLIKELY(0x0E)，对端收到错误响应。
   *
   * 表现：手机用"无响应写"完全正常，Windows 用"带响应写"报
   *       Protocol Error 0x0E: Unlikely Error（但灯其实已亮）。
   */

  return len;
''')
if new_body == body:
    print('  !! 没找到 return OK')
    sys.exit(0)

s = s[:start] + new_body + s[end:]
io.open(p, 'w', encoding='utf-8').write(s)
print('  patched')
PYEOF_INNER2

#----------------------------------------------------------------------------
echo "[6/7] bt_conn : 断开后强制回收连接槽位"
python3 - <<'PYEOF_INNER'
import io, sys
V = __import__('os').environ.get('VELA_ROOT', __import__('os').path.expanduser('~') + '/openvela')
N = V + '/nuttx'
CONN = N + '/wireless/bluetooth/bt_conn.c'
HDR = N + '/wireless/bluetooth/bt_conn.h'
HCI = N + '/wireless/bluetooth/bt_hcicore.c'

s = io.open(CONN, encoding='utf-8').read()
if 'BTSH_CONN_RECLAIM' in s:
    print('  skip'); sys.exit(0)

# 1) bt_conn.c: 前向声明 + 实现
s = s.replace('void bt_conn_release(FAR struct bt_conn_s *conn)\n{',
              'void bt_conn_reclaim(FAR struct bt_conn_s *conn);\n\n'
              'void bt_conn_release(FAR struct bt_conn_s *conn)\n{', 1)

marker = '  bt_addr_le_copy(&conn->dst, BT_ADDR_LE_ANY);\n}\n'
idx = s.index(marker, s.index('void bt_conn_release(FAR struct bt_conn_s *conn)'))
end = idx + len(marker)

impl = """

void bt_conn_reclaim(FAR struct bt_conn_s *conn)
{
  if (conn->state != BT_CONN_DISCONNECTED)
    {
      return;
    }

  bt_atomic_set(&conn->ref, 0);
  bt_addr_le_copy(&conn->dst, BT_ADDR_LE_ANY);
}
"""
s = s[:end] + impl + s[end:]
io.open(CONN, 'w', encoding='utf-8').write(s)

# 2) 头文件声明
h = io.open(HDR, encoding='utf-8').read()
if 'bt_conn_reclaim' not in h:
    h = h.replace('void bt_conn_release(FAR struct bt_conn_s *conn);',
                  'void bt_conn_release(FAR struct bt_conn_s *conn);\n\n'
                  '/* BTSH_CONN_RECLAIM */\nvoid bt_conn_reclaim(FAR struct bt_conn_s *conn);', 1)
    io.open(HDR, 'w', encoding='utf-8').write(h)

# 3) 断开流程里调用
c = io.open(HCI, encoding='utf-8').read()
if 'bt_conn_reclaim(conn)' not in c:
    c = c.replace('  bt_conn_release(conn);\n\n  if (g_btdev.adv_enable)',
                  '  bt_conn_release(conn);\n\n  bt_conn_reclaim(conn);\n\n'
                  '  if (g_btdev.adv_enable)', 1)
    io.open(HCI, 'w', encoding='utf-8').write(c)

print('  patched')
PYEOF_INNER

#----------------------------------------------------------------------------
echo "[7/7] 生成 production 配置（关闭主机流控 + 放宽连接槽位）"
P=$(cd "$(dirname "$0")" && pwd)
B=$N/boards/risc-v/esp32c3/esp32c3-generic
VB=$V/vendor/espressif/boards/esp32c3/esp32c3-generic
python3 - "$P/defconfig-btlight-auto" "$P/defconfig-production" <<'PYEOF'
import io, re, sys
src, dst = sys.argv[1], sys.argv[2]
s = io.open(src, encoding='utf-8').read()
s = s.replace('CONFIG_UART0_SERIAL_CONSOLE=y\n', '')
if 'CONFIG_ESPRESSIF_USBSERIAL' not in s:
    s = s.replace('CONFIG_ESPRESSIF_SPI2_MOSIPIN=4\n',
                  'CONFIG_ESPRESSIF_SPI2_MOSIPIN=4\n'
                  'CONFIG_ESPRESSIF_USBSERIAL=y\n', 1)
if 'CONFIG_SYSLOG_CONSOLE' not in s:
    s = s.rstrip() + '\nCONFIG_SYSLOG_CONSOLE=y\n'
if 'CONFIG_BLUETOOTH_CNTRL_HOST_FLOW_DISABLE' not in s:
    s = s.replace('# CONFIG_BLUETOOTH_CNTRL_HOST_FLOW_DISABLE is not set\n', '')
    s = s.rstrip() + '\nCONFIG_BLUETOOTH_CNTRL_HOST_FLOW_DISABLE=y\n'
# 设备名：NuttX 初始化时会用它自己的默认名（DEVICE_LOCAL_NAME="NuttX"）
# 抢先广播一次，中心设备会缓存这个名字，导致显示成 NuttX。
# 两个都要改：LOCAL_NAME 用于广播，DEVICE_NAME 用于 GAP 设备名特征。
for key, val in (('DEVICE_LOCAL_NAME', '"BTSH-LIGHT"'),
                 ('DEVICE_NAME', '"BTSH-LIGHT"')):
    if 'CONFIG_%s=' % key not in s:
        s = s.rstrip() + '\nCONFIG_%s=%s\n' % (key, val)

s = re.sub(r'^CONFIG_BLUETOOTH_MAX_CONN=\d+$', 'CONFIG_BLUETOOTH_MAX_CONN=8', s, flags=re.M)
if 'CONFIG_BLUETOOTH_MAX_CONN=' not in s:
    s = s.rstrip() + '\nCONFIG_BLUETOOTH_MAX_CONN=8\n'
io.open(dst, 'w', encoding='utf-8').write(s)
print('  written')
PYEOF
mkdir -p "$B/configs/production" "$VB/configs/production"
cp -f "$P/defconfig-production" "$B/configs/production/defconfig"
cp -f "$P/defconfig-production" "$VB/configs/production/defconfig"
echo "  已安装 production 配置"

echo
echo "全部完成。构建："
echo "  ./build.sh vendor/espressif/boards/esp32c3/esp32c3-generic/configs/production/ -j20"
