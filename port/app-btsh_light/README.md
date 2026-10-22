# btsh_light（已应用到 ESP32-C3 板）

这是 openvela 自带 `apps/wireless/bluetooth/btsh_light` 在本项目里**已修补的最终版本**。

相对原版（OpenvelaESP-BTSH 项目）的改动：

1. `btsh_light_main.c`
   - 补 `bt_start_advertising()` / `bt_stop_advertising()` 的 extern 声明
     （这两个函数在 `wireless/bluetooth/bt_hcicore.c` 里实现，但本树没有公开头文件声明）
   - 删除未使用的 `static struct _bt_gatt_ccc_s g_state_ccc;`
     （`BT_GATT_CCC()` 宏自己会构造复合字面量，这个变量多余且触发 `-Werror`）
   - **`btsh_light_apply()` 改为按 ws2812 驱动格式写 N 颗灯珠**
     （原实现写 8 字节结构体 → 被当成 2 颗灯，第 3~5 颗不更新）
   - 新增 `btsh_light_set_rgb()` 与 `btsh_light_selftest()`
   - 新增 `test` 子命令：`btsh_light test` 做 R/G/B/W 循环，**不依赖 BLE**
- **逐灯 RGB**：`g_px[]` 作为颜色真源，`0xFF01` 写 4 字节
    `[index,R,G,B]`（index 0xFF = 全部）；1 字节写入仍是开/关
2. `Kconfig`
   - 新增 `CONFIG_BTSH_LIGHT_LED_COUNT`（默认 5，须与板级
     `CONFIG_ESP32C3_GENERIC_WS2812_NLEDS` 一致）

直接用这几份文件覆盖 `apps/wireless/bluetooth/btsh_light/` 下同名文件即可，
等价于 `apply-all.sh` 的第 8/8b/8c 步。
