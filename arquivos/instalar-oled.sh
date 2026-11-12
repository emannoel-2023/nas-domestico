#!/usr/bin/env bash
# =============================================================================
#  instalar-oled.sh - liga a tela OLED (0,96" SSD1306 I2C) num NAS que JA esta
#  funcionando (Armbian na ROCK 4B+), sem mexer em mais nada do sistema.
#
#    curl -fsSL https://raw.githubusercontent.com/emannoel-2023/nas-domestico/main/arquivos/instalar-oled.sh | sudo bash
#    sudo bash instalar-oled.sh            (de dentro do repositorio clonado)
#    sudo bash instalar-oled.sh --remover  desfaz tudo
#
#  O que faz: copia o nas-oled.py e o servico nas-oled, e liga o I2C7 (pinos 3 e
#  5) no /boot/armbianEnv.txt, guardando uma copia em armbianEnv.txt.antes-oled.
#  Ligacao da tela: GND=6, VCC=1 (3,3 V), SCL=5, SDA=3.
# =============================================================================
set -euo pipefail
REPO="${NAS_REPO:-https://raw.githubusercontent.com/emannoel-2023/nas-domestico/main}"
ENV=/boot/armbianEnv.txt
COPIA="$ENV.antes-oled"
DESTINO=/usr/local/lib/nas/nas-oled.py
SERVICO=/etc/systemd/system/nas-oled.service

[[ $EUID -eq 0 ]] || { echo "Rode com sudo."; exit 1; }

if [[ "${1:-}" == "--remover" ]]; then
  systemctl disable --now nas-oled.service 2>/dev/null || true
  rm -f "$SERVICO" "$DESTINO"
  if [[ -f "$COPIA" ]]; then cp -p "$COPIA" "$ENV"; rm -f "$COPIA"; fi
  systemctl daemon-reload
  echo "Tela OLED removida. O I2C7 desliga no proximo boot (sudo reboot)."
  exit 0
fi

command -v python3 >/dev/null || { echo "Falta o python3 (sudo apt install python3)."; exit 1; }
[[ -f "$ENV" ]] || { echo "Nao achei $ENV: este nao parece um Armbian."; exit 1; }
ls /boot/dtb/rockchip/overlay/rockchip-rk3399-i2c7.dtbo >/dev/null 2>&1 \
  || { echo "Nao achei o overlay do I2C7 (rockchip-rk3399-i2c7.dtbo) neste kernel."; exit 1; }

# Arquivos: da pasta do script (repositorio clonado) ou do GitHub
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
aqui="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo /nao-existe)"
for f in nas-oled.py nas-oled.service; do
  if [[ -f "$aqui/$f" ]]; then cp "$aqui/$f" "$tmp/$f"
  else curl -fsSL --retry 3 "$REPO/arquivos/$f" -o "$tmp/$f"; fi
done
python3 -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$tmp/nas-oled.py"
grep -q '^ExecStart=' "$tmp/nas-oled.service"

install -D -m 755 "$tmp/nas-oled.py" "$DESTINO"
install -D -m 644 "$tmp/nas-oled.service" "$SERVICO"

# Liga o I2C7 no boot (so acrescenta; guarda a versao original uma vez)
[[ -f "$COPIA" ]] || cp -p "$ENV" "$COPIA"
if ! grep -q 'rk3399-i2c7' "$ENV"; then
  [[ -z "$(tail -c1 "$ENV")" ]] || echo >> "$ENV"
  if grep -q '^overlays=' "$ENV"; then sed -i 's/^overlays=\(.*\)$/overlays=\1 rk3399-i2c7/' "$ENV"
  else echo "overlays=rk3399-i2c7" >> "$ENV"; fi
fi
echo "armbianEnv.txt: $(grep '^overlays=' "$ENV")"

systemctl daemon-reload
systemctl enable nas-oled.service >/dev/null 2>&1
if [[ -e /dev/i2c-7 ]]; then
  systemctl restart nas-oled.service
  echo "Pronto: a tela ja deve mostrar o estado do NAS."
else
  echo "Pronto. Reinicie a placa para ligar o I2C7:  sudo reboot"
fi
echo "Para desfazer: sudo bash instalar-oled.sh --remover   (ou o mesmo comando curl com --remover no fim: | sudo bash -s -- --remover)"
