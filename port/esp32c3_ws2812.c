/****************************************************************************
 * boards/risc-v/esp32c3/esp32c3-generic/src/esp32c3_ws2812.c
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * ESP32-C3-SmartHome-Actuator 板级 WS2812 初始化
 *
 *   由 DogKing 为「2026 首届 openvela AI 硬件开发者大赛」添加。
 *
 *   硬件：5 颗 WS2812B（LED3~LED7），数据线接 GPIO4，
 *         灯珠 VDD 由 5V 经 M7 降压到约 4.2V，DIN 串 330R 并有 SRV05-4 保护。
 *
 *   实现方式：用 SPI2 的 MOSI 模拟 WS2812 单总线时序
 *     - 通用驱动：drivers/leds/ws2812.c  (CONFIG_WS2812)
 *     - 注册接口：ws2812_leds_register()
 *     - 引脚由 defconfig 指定：CONFIG_ESPRESSIF_SPI2_MOSIPIN=4
 *
 *   WS2812 没有 CS/RESET，独占 SPI2。
 *
 ****************************************************************************/

/****************************************************************************
 * Included Files
 ****************************************************************************/

#include <nuttx/config.h>

#include <debug.h>
#include <errno.h>
#include <stdio.h>

#include <nuttx/leds/ws2812.h>
#include <nuttx/spi/spi.h>

#include "espressif/esp_spi.h"

#if defined(CONFIG_WS2812) && !defined(CONFIG_WS2812_NON_SPI_DRIVER) && \
    defined(CONFIG_ESPRESSIF_SPI)

/****************************************************************************
 * Public Functions
 ****************************************************************************/

/****************************************************************************
 * Name: board_ws2812_initialize
 *
 * Description:
 *   Initialize and register the WS2812 LED driver.
 *
 * Input Parameters:
 *   devno - The device number, used to build the device path as /dev/ledsN
 *   spino - SPI port number
 *   nleds - Number of LEDs chained
 *
 * Returned Value:
 *   Zero (OK) on success; a negated errno value on failure.
 *
 ****************************************************************************/

int board_ws2812_initialize(int devno, int spino, uint16_t nleds)
{
  FAR struct spi_dev_s *spi;
  char devpath[16];
  int ret;

  spi = esp_spibus_initialize(spino);
  if (spi == NULL)
    {
      lederr("ERROR: esp_spibus_initialize(%d) failed\n", spino);
      return -ENODEV;
    }

  snprintf(devpath, sizeof(devpath), "/dev/leds%d", devno);

  ret = ws2812_leds_register(devpath, spi, nleds);
  if (ret < 0)
    {
      lederr("ERROR: ws2812_leds_register(%s) failed: %d\n", devpath, ret);
      return ret;
    }

  ledinfo("WS2812: %s registered, %u LED(s), SPI%d\n",
          devpath, (unsigned)nleds, spino);
  return OK;
}

#endif /* CONFIG_WS2812 && !CONFIG_WS2812_NON_SPI_DRIVER && CONFIG_ESPRESSIF_SPI */
