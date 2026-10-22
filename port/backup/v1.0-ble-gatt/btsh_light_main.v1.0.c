/****************************************************************************
 * apps/wireless/bluetooth/btsh_light/btsh_light_main.c
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * 由 OpenvelaESP-BTSH 项目编写
 *
 * BLE GATT 灯控服务（下位机 = Peripheral / GATT Server）
 *
 * ## 项目背景
 *
 * Radxa A7Z 上位机（BLE Central）通过蓝牙控制本 ESP32-S3-N16R8 下位机，
 * 实现远程点灯。本项目第一阶段只做「远程开关灯」。
 *
 * ## 提供的 GATT 服务
 *
 *   Service UUID  0xFF00  （自定义 16 位）
 *   ├─ 0xFF01  灯控命令特征   WRITE         写入 1 字节：0=关灯 1=开灯
 *   ├─ 0xFF02  灯状态特征     READ  + NOTIFY 读 1 字节：0=关 1=开
 *   └─ 0xFF03  设备信息特征   READ           读 3 字节：版本1 + 通道数1 + 保留1
 *
 * ## 为什么用 16 位 UUID
 *
 * NuttX 的 `BT_GATT_PRIMARY_SERVICE()` 宏内部把服务属性的 UUID 类型硬编码为
 * `BT_UUID_16`（见 include/nuttx/wireless/bluetooth/bt_gatt.h:222-235），
 * 因此**当前实现无法声明 128 位服务 UUID**。
 * 这里采用 16 位自定义 UUID，并避开 Bluetooth SIG 已分配的常用值。
 *
 * ## 物理输出
 *
 * 第一阶段把「灯」映射到**板载 WS2812B (GPIO48)**，便于无外接硬件时验证：
 *   开灯 -> 绿色常亮
 *   关灯 -> 熄灭（暗红表示蓝牙未连接）
 * 后续接继电器后只需替换 `btsh_light_apply()` 的实现。
 *
 * ## 用法（NSH）
 *
 *   btsh_light start    启动服务并开始广播
 *   btsh_light stop     停止广播
 *   btsh_light state    查看当前灯状态与连接状态
 *
 ****************************************************************************/

/****************************************************************************
 * Included Files
 ****************************************************************************/

#include <nuttx/config.h>

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <unistd.h>

#include <nuttx/wireless/bluetooth/bt_core.h>
#include <nuttx/wqueue.h>

/* BTSH_EXTERN_ADV_API
 *
 * bt_start_advertising()/bt_stop_advertising() are implemented in
 * wireless/bluetooth/bt_hcicore.c but are NOT declared in any public
 * NuttX header in this tree.  Declare them here so the GATT server can
 * start/stop advertising in the flat build.
 */

int bt_start_advertising(uint8_t type, FAR const struct bt_eir_s *ad,
                         FAR const struct bt_eir_s *sd);
int bt_stop_advertising(void);

/* BTSH_CONN_CB_API: 连接状态回调结构体与注册函数定义在
 * wireless/bluetooth/bt_hcicore.h（内部头文件，不在 include/ 里），
 * 应用侧只能自行声明，布局必须与内核侧一致。
 *
 * 为什么需要它：控制器在建立连接时会自动停止广播，而断开后协议栈
 * 不会自动恢复。没有这个回调，中心设备连一次再断开，本机就永久
 * 不可见，只能重启。
 */

struct bt_conn_s;

struct bt_conn_cb_s
{
  FAR struct bt_conn_cb_s *flink;
  FAR void *context;
  CODE void (*connected)(FAR struct bt_conn_s *conn, FAR void *context);
  CODE void (*disconnected)(FAR struct bt_conn_s *conn, FAR void *context);
};

void bt_conn_cb_register(FAR struct bt_conn_cb_s *cb);

#include <nuttx/wireless/bluetooth/bt_gatt.h>
#include <nuttx/wireless/bluetooth/bt_hci.h>
#include <nuttx/wireless/bluetooth/bt_uuid.h>

/* ⚠️ 连接状态回调 bt_conn_cb_register() 声明在**内部头**
 * nuttx/wireless/bluetooth/bt_hcicore.h 里，而该目录不在 apps 的
 * include 路径中（见 nuttx/wireless/bluetooth/Make.defs:41 —— 那条
 * CFLAGS 只作用于编译 wireless 库自身时）。
 *
 * 因此本应用**不注册连接回调**，改用以下方式：
 *   - 写入命令时点亮/熄灭板载 RGB（功能不受影响）
 *   - 通过 `btsh_light state` 命令查看状态
 * 若将来需要精确的连接事件，可在 NuttX 内部加钩子，
 * 或改用 SIOCBT* ioctl 轮询。
 */

/****************************************************************************
 * Pre-processor Definitions
 ****************************************************************************/

/* 属性表句柄编号。
 * NuttX 的 GATT 表是静态句柄表，句柄值即数组下标，必须唯一且连续。
 */

/* ★ 句柄必须从 1 开始！
 * ATT 协议规定 0x0000 是**无效句柄**（"invalid handle"）。
 * 若把主服务放在句柄 0，中央设备做服务发现时会读不到，
 * 表现为连接后 get_services() 超时而断开（实测踩过这个坑）。
 *
 * 权威参照：NuttX 自带的 GAP 服务实现
 *   wireless/bluetooth/bt_services.c:  #define GASVC 0x0001
 *
 * 这里沿用同样风格：基址 + 偏移。
 */

#define BTSH_SVC_BASE          0x0001

#define BTSH_SVC_HANDLE        (BTSH_SVC_BASE + 0)  /* 主服务 */
#define BTSH_CMD_CHRC_HANDLE   (BTSH_SVC_BASE + 1)  /* 命令特征声明 */
#define BTSH_CMD_VAL_HANDLE    (BTSH_SVC_BASE + 2)  /* 命令特征值（可写） */
#define BTSH_STATE_CHRC_HANDLE (BTSH_SVC_BASE + 3)  /* 状态特征声明 */
#define BTSH_STATE_VAL_HANDLE  (BTSH_SVC_BASE + 4)  /* 状态特征值（读+Notify） */
#define BTSH_STATE_CCC_HANDLE  (BTSH_SVC_BASE + 5)  /* 状态特征 CCC */
#define BTSH_INFO_CHRC_HANDLE  (BTSH_SVC_BASE + 6)  /* 设备信息特征声明 */
#define BTSH_INFO_VAL_HANDLE   (BTSH_SVC_BASE + 7)  /* 设备信息特征值（可读） */
#define BTSH_ATTR_COUNT        8

/* 自定义 16 位 UUID（避开 Bluetooth SIG 常用分配） */

#define BTSH_UUID_SERVICE  0xff00
#define BTSH_UUID_CMD      0xff01
#define BTSH_UUID_STATE    0xff02
#define BTSH_UUID_INFO     0xff03

/* 灯控命令字节 */

#define BTSH_CMD_OFF       0x00
#define BTSH_CMD_ON        0x01

/* 4 字节 RGB 写入时的 index 特殊值：整条灯带 */

#define BTSH_RGB_ALL       0xff

/* 设备信息：协议版本 */

#define BTSH_PROTO_VERSION 0x01
#define BTSH_CHANNELS      0x01    /* 第一阶段：单路 */

/* 广播名（可在 defconfig 用 CONFIG_BTSH_LIGHT_ADV_NAME 覆盖） */

#ifndef CONFIG_BTSH_LIGHT_ADV_NAME
#  define CONFIG_BTSH_LIGHT_ADV_NAME "BTSH-LIGHT"
#endif

/* 板载 WS2812 设备节点与颜色 */

#ifndef CONFIG_BTSH_LIGHT_LED_DEV
#  define CONFIG_BTSH_LIGHT_LED_DEV "/dev/leds0"
#endif

/* 板上有几颗 WS2812B（须与板级 CONFIG_ESP32C3_GENERIC_WS2812_NLEDS 一致） */

#ifndef CONFIG_BTSH_LIGHT_LED_COUNT
#  define BTSH_LED_COUNT 5
#else
#  define BTSH_LED_COUNT CONFIG_BTSH_LIGHT_LED_COUNT
#endif

#define BTSH_WS2812_MAGIC 0x0000aa55   /* NuttX ws2812 驱动的字节序标记 */

/****************************************************************************
 * Private Types
 ****************************************************************************/

/* NuttX ws2812 驱动接受 4 字节/LED：魔数 + r + g + b
 * （见 drivers/leds/ws2812.c 与 apps/examples/ws2812）
 * 这里用 struct 保证布局，再用 memcpy 写入，避免对齐问题。
 */

struct btsh_rgb_s
{
  uint32_t magic;   /* 固定为 0x0000aa55 */
  uint8_t  r;
  uint8_t  g;
  uint8_t  b;
};

/****************************************************************************
 * Private Data
 ****************************************************************************/

/* 当前灯状态（第一阶段的"灯"= 板载 WS2812） */

static uint8_t g_light_state = BTSH_CMD_OFF;

/* 每颗灯的当前颜色（0x00RRGGBB）。作为唯一真源，所有写入都先改这里再 flush。 */

static uint32_t g_px[BTSH_LED_COUNT];
static int     g_led_fd      = -1;

/* 静态广播数据。注意 AD 结构的 len 字段必须等于
 * 「type 长度(1) + 数据长度」，这是 S3 阶段从 btsak 的缺陷中学到的。
 */

static struct bt_eir_s g_adv_data[2];
static struct bt_eir_s g_scan_rsp[2];

/* GATT 属性表 */

static struct bt_uuid_s g_svc_uuid =
{
  .type = BT_UUID_16,
  .u.u16 = BTSH_UUID_SERVICE,
};

static struct bt_uuid_s g_cmd_uuid =
{
  .type = BT_UUID_16,
  .u.u16 = BTSH_UUID_CMD,
};

static struct bt_uuid_s g_state_uuid =
{
  .type = BT_UUID_16,
  .u.u16 = BTSH_UUID_STATE,
};

static struct bt_uuid_s g_info_uuid =
{
  .type = BT_UUID_16,
  .u.u16 = BTSH_UUID_INFO,
};

/* 命令特征：只写 */

static struct bt_gatt_chrc_s g_cmd_chrc =
{
  .properties   = BT_GATT_CHRC_WRITE | BT_GATT_CHRC_WRITE_WITHOUT_RESP,
  .value_handle = BTSH_CMD_VAL_HANDLE,
  .uuid         = &g_cmd_uuid,
};

/* 状态特征：读 + 通知 */

static struct bt_gatt_chrc_s g_state_chrc =
{
  .properties   = BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY,
  .value_handle = BTSH_STATE_VAL_HANDLE,
  .uuid         = &g_state_uuid,
};

/* 设备信息特征：只读 */

static struct bt_gatt_chrc_s g_info_chrc =
{
  .properties   = BT_GATT_CHRC_READ,
  .value_handle = BTSH_INFO_VAL_HANDLE,
  .uuid         = &g_info_uuid,
};

/* 设备信息内容：版本 + 通道数 + 保留 */

static uint8_t g_dev_info[3] =
{
  BTSH_PROTO_VERSION,
  BTSH_CHANNELS,
  0x00,
};

/* CCC（Client Characteristic Configuration）配置表。
 *
 * ★★ 这里曾经是一个严重 bug，导致 BLE 一连接就崩溃复位 ★★
 *
 * 错误写法（旧）：
 *     static uint16_t g_state_ccc;          // 只有 2 字节
 *     BT_GATT_CCC(HANDLE, VAL_HANDLE, &g_state_ccc, NULL)
 *
 * 为什么错：BT_GATT_CCC 宏把第 3 个参数当作
 * **`struct bt_gatt_ccc_cfg_s` 的数组**，展开后是：
 *     .user_data = (&(struct _bt_gatt_ccc_s) {
 *                    .cfg     = _cfg,
 *                    .cfg_len = nitems(_cfg),
 *                    ...
 *                  })
 * 而 bt_gatt_attr_read_ccc() / write_ccc() 会立刻做
 *     ccc->cfg_len      // 读 size_t
 *     ccc->cfg[i].peer  // 解引用 FAR 指针
 * 把 2 字节的 uint16_t 当成含指针的结构体来解引用，
 * 读到的是垃圾指针 -> 访问非法地址 -> 复位。
 *
 * 表现（本项目实测）：
 *     手机/电脑一发起 BLE 连接 -> le_conn_complete status 0
 *     -> bt_gatt_connected -> 随即 rst:0x13 (GLITCH_RTC_RST)
 *     -> 重启、重新广播、又被连、又崩（约 2 秒一轮）
 *     日志里始终看不到 ACL 数据，因为板子在收到数据前就崩了。
 *
 * 正确写法：给一个配置项数组（对应"每个对端一份订阅配置"）。
 * 注意 NuttX 全树**没有任何 BT_GATT_CCC 的使用范例**，
 * 上面的宏展开是唯一的权威依据（bt_gatt.h:316-330）。
 */

static struct bt_gatt_ccc_cfg_s g_state_ccc_cfg[CONFIG_BLUETOOTH_MAX_PAIRED];

/****************************************************************************
 * Private Function Prototypes
 ****************************************************************************/

static int  btsh_read_state(FAR struct bt_conn_s *conn,
                            FAR const struct bt_gatt_attr_s *attr,
                            FAR void *buf, uint8_t len, uint16_t offset);
static int  btsh_write_cmd(FAR struct bt_conn_s *conn,
                           FAR const struct bt_gatt_attr_s *attr,
                           FAR const void *buf, uint8_t len, uint16_t offset);
static int  btsh_read_info(FAR struct bt_conn_s *conn,
                           FAR const struct bt_gatt_attr_s *attr,
                           FAR void *buf, uint8_t len, uint16_t offset);
static void btsh_light_apply(uint8_t state);

/****************************************************************************
 * Private Data (GATT 属性表)
 ****************************************************************************/

static const struct bt_gatt_attr_s g_attrs[] =
{
  BT_GATT_PRIMARY_SERVICE(BTSH_SVC_HANDLE, &g_svc_uuid),

  /* 灯控命令：写入 1 字节 */

  BT_GATT_CHARACTERISTIC(BTSH_CMD_CHRC_HANDLE, &g_cmd_chrc),
  BT_GATT_DESCRIPTOR(BTSH_CMD_VAL_HANDLE, &g_cmd_uuid,
                     BT_GATT_PERM_WRITE,
                     NULL, btsh_write_cmd, NULL),

  /* 灯状态：可读 + Notify */

  BT_GATT_CHARACTERISTIC(BTSH_STATE_CHRC_HANDLE, &g_state_chrc),
  BT_GATT_DESCRIPTOR(BTSH_STATE_VAL_HANDLE, &g_state_uuid,
                     BT_GATT_PERM_READ,
                     btsh_read_state, NULL, NULL),
  /* 第 3 个参数必须是**数组**（对应每个对端的订阅配置） */
  BT_GATT_CCC(BTSH_STATE_CCC_HANDLE, BTSH_STATE_VAL_HANDLE,
              g_state_ccc_cfg, NULL),

  /* 设备信息：只读 3 字节 */

  BT_GATT_CHARACTERISTIC(BTSH_INFO_CHRC_HANDLE, &g_info_chrc),
  BT_GATT_DESCRIPTOR(BTSH_INFO_VAL_HANDLE, &g_info_uuid,
                     BT_GATT_PERM_READ,
                     btsh_read_info, NULL, g_dev_info),
};



/****************************************************************************
 * Private Functions
 ****************************************************************************/

/****************************************************************************
 * Name: btsh_light_apply
 *
 * Description:
 *   把逻辑灯状态写到物理输出。
 *
 *   第一阶段映射到板载 WS2812B（GPIO4，5 颗）：
 *     开 -> 绿
 *     关 -> 灭
 *   以后接继电器时，只需改这里的实现（写 GPIO），上层不用动。
 *
 ****************************************************************************/

static uint32_t btsh_rgb(uint8_t r, uint8_t g, uint8_t b)
{
  return ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
}

/* 把 g_px 整体写到 /dev/leds0。
 * NuttX ws2812(SPI) 格式：每灯一个 32 位字 0x00RRGGBB，
 * 长度须为 4 的整数倍，偏移 0 表示从第 1 颗开始。
 */

static int btsh_light_flush(void)
{
  ssize_t n;

  if (g_led_fd < 0)
    {
      return -ENODEV;
    }

  if (lseek(g_led_fd, 0, SEEK_SET) < 0)
    {
      syslog(LOG_ERR, "BTSH: lseek failed\n");
      return -EIO;
    }

  n = write(g_led_fd, g_px, sizeof(g_px));
  if (n < (ssize_t)sizeof(g_px))
    {
      syslog(LOG_ERR, "BTSH: ws2812 write %d/%u failed\n",
             (int)n, (unsigned)sizeof(g_px));
      return -EIO;
    }

  return OK;
}

/* 整条灯带同一颜色 */

static int btsh_light_set_all(uint8_t r, uint8_t g, uint8_t b)
{
  size_t i;

  for (i = 0; i < BTSH_LED_COUNT; i++)
    {
      g_px[i] = btsh_rgb(r, g, b);
    }

  return btsh_light_flush();
}

/* 单颗灯 */

static int btsh_light_set_one(size_t idx, uint8_t r, uint8_t g, uint8_t b)
{
  if (idx >= BTSH_LED_COUNT)
    {
      return -EINVAL;
    }

  g_px[idx] = btsh_rgb(r, g, b);
  return btsh_light_flush();
}

/* 兼容旧接口（自检命令用）：整条灯带同色 */

static int btsh_light_set_rgb(uint8_t r, uint8_t g, uint8_t b)
{
  return btsh_light_set_all(r, g, b);
}

/* 汇总状态：有任意一颗亮就算 ON */

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

static void btsh_light_apply(uint8_t state)
{
  if (state == BTSH_CMD_ON)
    {
      btsh_light_set_all(0, 40, 0);      /* 绿色：开 */
    }
  else
    {
      btsh_light_set_all(0, 0, 0);       /* 熄灭：关 */
    }

  syslog(LOG_INFO, "BTSH: %u LED(s) -> %s\n", (unsigned)BTSH_LED_COUNT,
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

  printf("WS2812 self-test: %u LED(s) on %s (fd=%d)\n",
         (unsigned)BTSH_LED_COUNT, CONFIG_BTSH_LIGHT_LED_DEV, g_led_fd);

  if (g_led_fd < 0)
    {
      printf("  ERROR: LED device not open.\n");
      printf("         Check CONFIG_WS2812 / poll: %s\n",
             CONFIG_BTSH_LIGHT_LED_DEV);
      return;
    }

  for (i = 0; i < sizeof(seq) / sizeof(seq[0]); i++)
    {
      printf("  %s\n", seq[i].name);
      ret = btsh_light_set_rgb(seq[i].r, seq[i].g, seq[i].b);
      if (ret < 0)
        {
          printf("  ERROR: write failed: %d\n", ret);
          break;
        }

      usleep(400 * 1000);
    }

  btsh_light_set_rgb(0, 0, 0);

  /* 恢复逻辑状态 */

  btsh_light_apply(g_light_state);

  printf("  done%s\n", ret < 0 ? " (with errors)" : "");
}

/****************************************************************************
 * Name: btsh_read_state
 *
 * Description:
 *   状态特征读回调：返回当前灯状态 1 字节。
 *
 ****************************************************************************/

static int btsh_read_state(FAR struct bt_conn_s *conn,
                           FAR const struct bt_gatt_attr_s *attr,
                           FAR void *buf, uint8_t len, uint16_t offset)
{
  UNUSED(attr);
  return bt_gatt_attr_read(conn, attr, buf, len, offset,
                           &g_light_state, sizeof(g_light_state));
}

/****************************************************************************
 * Name: btsh_read_info
 *
 * Description:
 *   设备信息特征读回调：返回 3 字节。
 *
 ****************************************************************************/

static int btsh_read_info(FAR struct bt_conn_s *conn,
                          FAR const struct bt_gatt_attr_s *attr,
                          FAR void *buf, uint8_t len, uint16_t offset)
{
  return bt_gatt_attr_read(conn, attr, buf, len, offset,
                           g_dev_info, sizeof(g_dev_info));
}

/****************************************************************************
 * Name: btsh_write_cmd
 *
 * Description:
 *   灯控命令写回调。对端写入 1 字节：0=关灯，1=开灯。
 *   写完立即通过 Notify 回报实际状态。
 *
 ****************************************************************************/

static int btsh_write_cmd(FAR struct bt_conn_s *conn,
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
      syslog(LOG_ERR, "BTSH: bad cmd (len=%u offset=%u)\n", (unsigned)len,
             (unsigned)offset);
      return -EINVAL;
    }

  /* 4 字节：[index, R, G, B]
   *   index 0..N-1  单颗灯
   *   index 0xFF    整条灯带
   */

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
          syslog(LOG_ERR, "BTSH: rgb write failed: %d\n", ret);
          return ret;
        }

      syslog(LOG_INFO, "BTSH: rgb[%u] = %02x %02x %02x\n",
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

  /* 1 字节：开 / 关（旧协议） */

  if (len != 1)
    {
      syslog(LOG_ERR, "BTSH: unsupported cmd length %u\n", (unsigned)len);
      return -EINVAL;
    }

  if (cmd[0] != BTSH_CMD_OFF && cmd[0] != BTSH_CMD_ON)
    {
      syslog(LOG_ERR, "BTSH: unknown cmd 0x%02x\n", cmd[0]);
      return -EINVAL;
    }

  newstate = (cmd[0] == BTSH_CMD_ON) ? BTSH_CMD_ON : BTSH_CMD_OFF;

  if (newstate != g_light_state)
    {
      g_light_state = newstate;
      btsh_light_apply(g_light_state);

      /* 主动回报状态（需对端已使能 CCC） */

      bt_gatt_notify(BTSH_STATE_VAL_HANDLE, &g_light_state,
                     sizeof(g_light_state));
    }

  return OK;
}

/****************************************************************************
 * Public Functions
 ****************************************************************************/

/****************************************************************************
 * Name: btsh_light_start
 *
 * Description:
 *   注册 GATT 服务并开始广播。
 *
 *   注意：广播前先 bt_stop_advertising()。
 *   S3 阶段实测发现：冷启动直接 bt_start_advertising() 会因
 *   LE_SET_ADV_ENABLE 等不到控制器响应而返回 -EIO；
 *   先停一次可规避（见 tests/hardware/HT-05-ble-advertise.md）。
 *
 ****************************************************************************/

/* 断开后重播状态 */

static bool   g_adv_enabled  = false;
static bool   g_gatt_registered = false;
static bool   g_conn_cb_done = false;
static struct work_s         g_readv_work;
static struct bt_conn_cb_s   g_conn_cb;

/* 在 LPWORK 上重播（不能在 BT 接收线程里直接发 HCI 命令） */

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
      syslog(LOG_ERR, "BTSH: re-advertise failed: %d\n", ret);
    }
  else
    {
      syslog(LOG_INFO, "BTSH: re-advertising after disconnect\n");
    }
}

static void btsh_light_connected_cb(FAR struct bt_conn_s *conn,
                                    FAR void *context)
{
  syslog(LOG_INFO, "BTSH: central connected\n");
}

static void btsh_light_disconnected_cb(FAR struct bt_conn_s *conn,
                                       FAR void *context)
{
  /* 内核注释明确要求不可假定本回调的线程上下文 */

  syslog(LOG_INFO, "BTSH: central disconnected\n");
  (void)work_queue(LPWORK, &g_readv_work, btsh_light_readv_worker, NULL, 0);
}

static int btsh_light_start(void)
{
  int ret;

  /* 打开板载 WS2812（没有也不影响 BLE 功能） */

  if (g_led_fd < 0)
    {
      g_led_fd = open(CONFIG_BTSH_LIGHT_LED_DEV, O_WRONLY);
      if (g_led_fd < 0)
        {
          syslog(LOG_WARNING,
                 "BTSH: open %s failed: %d (continue without status LED)\n",
                 CONFIG_BTSH_LIGHT_LED_DEV, errno);
        }
    }

  /* 注册 GATT 服务 */

  /* GATT 服务只能注册一次：重复执行 start（或 stop 后再 start）
   * 会向属性表里再插一份，导致对端看到重复服务/句柄错乱。
   */

  if (!g_gatt_registered)
    {
      bt_gatt_register(g_attrs, nitems(g_attrs));
      g_gatt_registered = true;

      syslog(LOG_INFO, "BTSH: GATT service 0x%04x registered (%d attrs)\n",
             BTSH_UUID_SERVICE, BTSH_ATTR_COUNT);
    }

  /* 装填广播数据。len = 1(type) + 数据长度 —— S3 阶段学到的要点 */

  g_adv_data[0].len     = 2;
  g_adv_data[0].type    = BT_EIR_FLAGS;
  g_adv_data[0].data[0] = BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR;
  g_adv_data[1].len     = 0;
  g_adv_data[1].type    = 0;

  /* 扫描响应里放完整设备名 */
  /*
   * ★ Complete Local Name 必须**带字符串终止符**。
   *
   * 两次踩坑记录（2026-10-11）：
   *
   * 坑 1（声明长度与数据不符）：
   *     .len   = 1 + strlen(NAME);          // 11
   *     memcpy(data, NAME, strlen(NAME));   // 只拷 10，长度字段多 1
   *
   * 坑 2（去掉终止符 —— 也不对）：
   *     .len   = strlen(NAME);              // 10
   *     memcpy(data, NAME, strlen(NAME));   // 10
   *   实测结果是中心设备只解析到 "BTSH-LIGH"（少了最后一个字符）——
   *   因为 BT_EIR_NAME_COMPLETE 要求名字以 '\0' 结束，
   *   长度字段应**包含**该终止符。
   *
   * 正确写法（与 btsak 一致）：
   *     .len = strlen(NAME) + 1;                        // 含 '\0'
   *     memcpy(data, NAME, strlen(NAME) + 1);           // 连 '\0' 一起拷
   */

  g_scan_rsp[0].len  = strlen(CONFIG_BTSH_LIGHT_ADV_NAME) + 1;
  g_scan_rsp[0].type = BT_EIR_NAME_COMPLETE;
  memcpy(g_scan_rsp[0].data, CONFIG_BTSH_LIGHT_ADV_NAME,
         strlen(CONFIG_BTSH_LIGHT_ADV_NAME) + 1);
  g_scan_rsp[1].len  = 0;
  g_scan_rsp[1].type = 0;

  /* 先停一次广播，规避冷启动首次 EIO（见函数头注释） */

  (void)bt_stop_advertising();

  ret = bt_start_advertising(BT_LE_ADV_IND, g_adv_data, g_scan_rsp);
  if (ret < 0)
    {
      syslog(LOG_ERR, "BTSH: advertising failed: %d\n", ret);
      return ret;
    }

  btsh_light_apply(g_light_state);
  g_adv_enabled = true;

  if (!g_conn_cb_done)
    {
      g_conn_cb.context      = NULL;
      g_conn_cb.connected    = btsh_light_connected_cb;
      g_conn_cb.disconnected = btsh_light_disconnected_cb;

      /* bt_conn_cb_register() 是头插链表，重复注册会让链表成环 */

      bt_conn_cb_register(&g_conn_cb);
      g_conn_cb_done = true;
    }

  syslog(LOG_INFO, "BTSH: advertising as \"%s\"\n",
         CONFIG_BTSH_LIGHT_ADV_NAME);
  return OK;
}

/****************************************************************************
 * Name: btsh_light_stop
 ****************************************************************************/

static int btsh_light_stop(void)
{
  g_adv_enabled = false;
  (void)bt_stop_advertising();
  if (g_led_fd >= 0)
    {
      g_light_state = BTSH_CMD_OFF;
      btsh_light_apply(g_light_state);
    }

  syslog(LOG_INFO, "BTSH: advertising stopped\n");
  return OK;
}

/****************************************************************************
 * Name: btsh_light_main
 *
 * Description:
 *   NSH 命令入口：btsh_light <start|stop|state>
 *
 ****************************************************************************/

int main(int argc, FAR char *argv[])
{
  if (argc < 2)
    {
      printf("Usage: btsh_light <start|stop|state|test>\n");
      printf("  start  注册 GATT 灯控服务并开始广播\n");
      printf("  stop   停止广播\n");
      printf("  state  显示灯状态与连接状态\n");
      printf("  test   灯带自检（R/G/B/W 循环，不需要 BLE）\n");
      return ERROR;
    }

  if (strcmp(argv[1], "start") == 0)
    {
      return (btsh_light_start() == OK) ? OK : ERROR;
    }
  else if (strcmp(argv[1], "stop") == 0)
    {
      return (btsh_light_stop() == OK) ? OK : ERROR;
    }
  else if (strcmp(argv[1], "test") == 0)
    {
      btsh_light_selftest();
      return OK;
    }
  else if (strcmp(argv[1], "state") == 0)
    {
      printf("BTSH light service\n");
      printf("  service UUID : 0x%04x\n", BTSH_UUID_SERVICE);
      printf("  cmd   UUID   : 0x%04x (write)\n", BTSH_UUID_CMD);
      printf("  state UUID   : 0x%04x (read/notify)\n", BTSH_UUID_STATE);
      printf("  info  UUID   : 0x%04x (read)\n", BTSH_UUID_INFO);
      printf("  adv name     : %s\n", CONFIG_BTSH_LIGHT_ADV_NAME);
      printf("  LED device   : %s (fd=%d)\n", CONFIG_BTSH_LIGHT_LED_DEV,
             g_led_fd);
      printf("  light state  : %s\n",
             g_light_state == BTSH_CMD_ON ? "ON" : "OFF");
      return OK;
    }

  printf("btsh_light: unknown command '%s'\n", argv[1]);
  return ERROR;
}
