
# nas-domestico: a tela OLED (SSD1306 no I2C7, pinos 3 e 5) mostra "LIGANDO" logo no
# inicio do boot. Precisa do U-Boot do NAS (com o comando i2c). Com outro U-Boot, ou
# sem tela, os comandos abaixo falham em silencio e o boot continua normalmente.
if i2c dev 7 && i2c probe 0x3c && load ${devtype} ${devnum}:${distro_bootpart} ${load_addr} ${prefix}nas-oled-ligando.bin; then
	for c in ae d5 80 a8 3f d3 00 40 8d 14 20 00 a1 c8 da 12 81 8f d9 f1 db 40 a4 a6 21 00 7f 22 00 07; do i2c mw 0x3c 0 0x${c}; done
	i2c write ${load_addr} 0x3c 0x40 0x400 -s
	i2c mw 0x3c 0 0xaf
fi
