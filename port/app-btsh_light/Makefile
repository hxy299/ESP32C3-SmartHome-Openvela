############################################################################
# apps/wireless/bluetooth/btsh_light/Makefile
#
# 由 OpenvelaESP-BTSH 项目编写
#
# BLE GATT 灯控服务（下位机 GATT Server）
#
############################################################################

include $(APPDIR)/Make.defs

# BLE GATT light control service

MAINSRC = btsh_light_main.c

# Application info

PROGNAME  = $(CONFIG_BTSH_LIGHT_PROGNAME)
PRIORITY  = $(CONFIG_BTSH_LIGHT_PRIORITY)
STACKSIZE = $(CONFIG_BTSH_LIGHT_STACKSIZE)
MODULE    = $(CONFIG_BTSH_LIGHT)

include $(APPDIR)/Application.mk
