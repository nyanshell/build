# Allwinner R16 quad core SoC WiFi
BOARD_NAME="ClockworkPi Gameshell"
BOARDFAMILY="sun8i"
BOARD_MAINTAINER=""
BOOTCONFIG="clockworkpi-cpi3_defconfig"
OVERLAY_PREFIX="sun8i-r16"
KERNEL_TARGET="edge"
KERNEL_TEST_TARGET="edge"
KERNELBRANCH="tag:v6.18.16"
BOOT_FDT_FILE="sun8i-r16-clockworkpi-cpi3.dtb"

BOOTFS_TYPE="fat"
BOOT_FS_LABEL="BOOT"
SERIALCON="ttyS0:115200"
