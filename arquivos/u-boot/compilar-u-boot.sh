#!/usr/bin/env bash
# =============================================================================
#  compilar-u-boot.sh - recompila o bootloader (U-Boot) da ROCK 4B+ usado na
#  imagem do NAS. Igual ao U-Boot oficial, com 3 diferencas:
#    - comando "i2c" ligado (CONFIG_CMD_I2C);
#    - barramento I2C7 ligado (pinos 3 e 5), para a tela OLED mostrar "LIGANDO"
#      ~2 s depois de ligar a energia (antes do Linux);
#    - sem espera antes do boot (CONFIG_BOOTDELAY=0).
#
#  Rode como root num Ubuntu/Debian (inclusive WSL2):   sudo bash compilar-u-boot.sh
#  Resultado: idbloader.img e u-boot.itb nesta pasta (usados pelo gerar-imagem.sh).
# =============================================================================
set -euo pipefail
AQUI="$(cd "$(dirname "$0")" && pwd)"
W="${TRAB:-/var/tmp/nas-uboot}"
TFA_VERSAO="v2.12.0"        # ARM Trusted Firmware (BL31 do RK3399)
UBOOT_VERSAO="v2025.01"
mkdir -p "$W"; cd "$W"

export DEBIAN_FRONTEND=noninteractive
if ! command -v aarch64-linux-gnu-gcc >/dev/null || ! command -v arm-none-eabi-gcc >/dev/null; then
  apt-get update -qq
  apt-get install -y -qq build-essential gcc-aarch64-linux-gnu gcc-arm-none-eabi bison flex bc \
    python3-setuptools python3-pyelftools python3-dev swig libssl-dev device-tree-compiler \
    libgnutls28-dev uuid-dev git u-boot-tools >/dev/null
fi

echo "== TF-A $TFA_VERSAO"
[[ -d tfa ]] || git clone -q --depth 1 -b "$TFA_VERSAO" https://github.com/ARM-software/arm-trusted-firmware tfa
make -s -C tfa CROSS_COMPILE=aarch64-linux-gnu- PLAT=rk3399 bl31 -j"$(nproc)"

echo "== U-Boot $UBOOT_VERSAO"
[[ -d u-boot ]] || git clone -q --depth 1 -b "$UBOOT_VERSAO" https://github.com/u-boot/u-boot u-boot
cd u-boot
if ! grep -q 'nas-domestico' arch/arm/dts/rk3399-rock-pi-4-u-boot.dtsi; then
  cat >> arch/arm/dts/rk3399-rock-pi-4-u-boot.dtsi <<'EOF'

/* nas-domestico: I2C7 ligado para a tela OLED (SSD1306) mostrar "LIGANDO" no boot */
&i2c7 {
	status = "okay";
};
EOF
fi
make -s rock-pi-4-rk3399_defconfig
./scripts/config --enable CMD_I2C --enable DM_I2C --enable SYS_I2C_ROCKCHIP \
  --set-val BOOTDELAY 0 --enable OF_LIBFDT_OVERLAY --enable CMD_PART \
  --enable LEGACY_IMAGE_FORMAT --enable CMD_SETEXPR
make -s olddefconfig
make -s CROSS_COMPILE=aarch64-linux-gnu- BL31="$W/tfa/build/rk3399/release/bl31/bl31.elf" -j"$(nproc)"
cp idbloader.img u-boot.itb "$AQUI/"
cd "$AQUI" && sha256sum idbloader.img u-boot.itb | tee SHA256SUMS
