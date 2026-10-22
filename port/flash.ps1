<#
.SYNOPSIS
    ESP32-C3-SmartHome-Actuator  一键烧录（Windows 侧）

.DESCRIPTION
    本板使用 openvela/NuttX 的 **SIMPLE_BOOT（直接启动）** 模式：
    只需要烧一个 nuttx.bin 到 **地址 0x0000**，
    **不需要** ESP-IDF 二级 bootloader，**不需要**分区表。

    依据：nuttx/tools/espressif/Config.mk
        else ifeq ($(CONFIG_ESPRESSIF_SIMPLE_BOOT),y)
            APP_OFFSET     := 0x0000
            APP_IMAGE      := nuttx.bin

    当前配置：FLASH 4MB / DIO / 80MHz（见 .config 的 ESPRESSIF_FLASH_*）

.PARAMETER Port
    串口，例如 COM5

.PARAMETER NuttxBin
    nuttx.bin 路径。默认使用本目录下的 nuttx.bin；找不到则从 WSL 复制。

.EXAMPLE
    .\flash.ps1 -Port COM5
    .\flash.ps1 -Port COM5 -Baud 115200      # 烧录不稳时降速
    .\flash.ps1 -Port COM5 -Erase           # 先整片擦除
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Port,

    [int]$Baud = 921600,

    [string]$NuttxBin = "",

    [ValidateSet('4MB', '2MB', '8MB', '16MB')]
    [string]$FlashSize = '4MB',

    [switch]$Erase
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- 工具 -------------------------------------------------------------------
function Get-Esptool {
    foreach ($n in @('esptool', 'esptool.py')) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c) { return @{ Exe = $c.Source; Pre = @() } }
    }
    $py = Get-Command python -ErrorAction SilentlyContinue
    if ($py) { return @{ Exe = $py.Source; Pre = @('-m', 'esptool') } }
    throw "找不到 esptool。请先：pip install esptool"
}

# --- 定位 nuttx.bin ---------------------------------------------------------
if (-not $NuttxBin) { $NuttxBin = Join-Path $here 'nuttx.bin' }

if (-not (Test-Path $NuttxBin)) {
    Write-Host "本地没有 nuttx.bin，尝试从 WSL 复制 ..." -ForegroundColor Cyan
    $dst = Join-Path $here 'nuttx.bin'
    wsl -d Ubuntu-22.04 -- bash -lc "cp ~/openvela/nuttx/nuttx.bin /mnt/d/Myprogram/DeepSeekProgram/ESP32C3-SmartHome-One/port/nuttx.bin" | Out-Null
    $NuttxBin = $dst
    if (-not (Test-Path $NuttxBin)) { throw "找不到 nuttx.bin。请指定 -NuttxBin 或先编译。" }
}

$len = (Get-Item $NuttxBin).Length
$hash = (Get-FileHash $NuttxBin -Algorithm SHA256).Hash.Substring(0, 16)
Write-Host ""
Write-Host "  nuttx.bin : $NuttxBin" -ForegroundColor Green
Write-Host "  size      : $('{0:N0}' -f $len) bytes" -ForegroundColor Green
Write-Host "  sha256    : $hash…" -ForegroundColor DarkGray
Write-Host "  port      : $Port  @ $Baud" -ForegroundColor Green
Write-Host "  flash     : $FlashSize / DIO / 80MHz / offset 0x0 (SIMPLE_BOOT)" -ForegroundColor Green
Write-Host ""

$tool = Get-Esptool
$base = $tool.Pre
$exe  = $tool.Exe

# --- 可选：整片擦除 ---------------------------------------------------------
if ($Erase) {
    Write-Host "[擦除] 整片擦除 flash ..." -ForegroundColor Yellow
    & $exe @base --chip esp32c3 --port $Port --baud $Baud erase_flash
    if ($LASTEXITCODE -ne 0) { throw "erase_flash 失败（exit $LASTEXITCODE）" }
}

# --- 烧录 -------------------------------------------------------------------
Write-Host "[烧录] nuttx.bin -> 0x0000" -ForegroundColor Yellow
& $exe @base --chip esp32c3 --port $Port --baud $Baud `
    --before default_reset --after hard_reset `
    write_flash -fs $FlashSize -fm dio -ff 80m `
    0x0 $NuttxBin

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "烧录失败（exit $LASTEXITCODE）。排查顺序：" -ForegroundColor Red
    Write-Host "  1) 本板没有 BOOT 键！SW1 是用户键，与 GPIO9 无关。"
    Write-Host "     要强制进下载模式：用杜邦线/镊子把 GPIO9 短接到 GND，再点 SW2(EN) 复位"
    Write-Host "  2) 降低波特率：-Baud 115200"
    Write-Host "  3) 确认供电：Type-C 5V 正常、3.3V 有输出"
    Write-Host "  4) 串口被占用？关掉 serial_log.py / 串口助手 / nRF 相关工具再试"
    exit 1
}

Write-Host ""
Write-Host "烧录完成 ✅" -ForegroundColor Green
Write-Host ""
Write-Host "验证方法（无需 USB-TTL，同一根 Type-C 即可）：" -ForegroundColor Cyan
Write-Host "  1) 串口日志（控制台走 USB-Serial-JTAG）：" -ForegroundColor Gray
Write-Host "       python tools\serial_log.py -p $Port -b 115200" -ForegroundColor Gray
Write-Host "     应看到 nsh> 提示符 + 几条 BTSH 日志" -ForegroundColor Gray
Write-Host "  2) BLE 扫描（应能看到厂商能力声明）：" -ForegroundColor Gray
Write-Host "       python tools\ble_client.py --scan" -ForegroundColor Gray
Write-Host "  3) 全链路自检（会自动开关灯）：" -ForegroundColor Gray
Write-Host "       python tools\ble_client.py --selftest" -ForegroundColor Gray
