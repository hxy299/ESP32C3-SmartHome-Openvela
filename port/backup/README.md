# v1.0 备份（广播能力声明之前的版本）

这个目录是 **v1.1（加入广播能力声明）之前**的完整快照，用于回退对照。

| 文件 | 说明 |
|---|---|
| `nuttx-production-v1.0.bin` | v1.0 生产固件（USB 控制台），sha256 `fa6e7eb7…` |
| `nuttx-v1.0.bin` | v1.0 默认固件（UART0 控制台） |
| `btsh_light_main.v1.0.c` | v1.0 应用源码（**不含** `BTSH_DISCOVERY_ADV`） |
| `defconfig-production-v1.0` | v1.0 生产配置 |
| `BLE_PROTOCOL_A7Z.v1.0.md` | v1.0 协议文档（**无** §10 广播格式） |
| `README.v1.0.md` | v1.0 完整文档 |

## v1.0 与 v1.1 的唯一功能差异

| | v1.0 | v1.1 |
|---|---|---|
| 广播数据 | 只有 Flags | Flags + **厂商自定义数据（能力声明）** |
| 中心设备识别 | 靠名字 `BTSH-LIGHT` | **不连接即可识别**设备类型/灯数/能力 |
| GATT 服务与命令格式 | — | **完全相同（未改动）** |

> 也就是说：**v1.1 对 A7Z 侧是完全向后兼容的**——只认名字的旧实现照样能用。

## 如何回退

```powershell
cd port
.\flash.ps1 -Port COM6 -NuttxBin .\backup\v1.0-ble-gatt\nuttx-production-v1.0.bin
```

## Git 版本锚点

```
git tag v1.0-ble-gatt      # 对应提交 e6066db
```
