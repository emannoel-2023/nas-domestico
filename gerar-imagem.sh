#!/usr/bin/env bash
# =============================================================================
#  gerar-imagem.sh - cria a imagem do NAS (nas-tcc.img) a partir do Armbian
#  oficial da Radxa ROCK 4B+ (Debian 13 trixie, minimal/CLI).
#
#  Roda em qualquer Linux como root (inclusive WSL2 no Windows ou a propria placa):
#      sudo bash gerar-imagem.sh [pasta_de_saida]
#
#  O que faz: baixa a imagem oficial, confere o SHA-256, coloca dentro dela os
#  arquivos da pasta ./arquivos e liga os servicos de primeiro boot.
# =============================================================================
set -Eeuo pipefail

ORIGEM="${ARMBIAN_URL:-https://dl.armbian.com/rockpi-4bplus/Trixie_current_minimal}"
AQUI="$(cd "$(dirname "$0")" && pwd)"
ARQ="$AQUI/arquivos"
SAIDA="${1:-$AQUI/saida}"
TRAB="${TRAB:-/var/tmp/nas-imagem}"
NOME_HOST="nas"

[[ $EUID -eq 0 ]] || { echo "Rode como root (sudo)."; exit 1; }
for c in curl xz sha256sum sfdisk mount losetup; do
  command -v "$c" >/dev/null || { echo "Falta o comando $c"; exit 1; }
done
mkdir -p "$TRAB" "$SAIDA"
cd "$TRAB"

echo "== 1/5 Baixando o Armbian oficial"
if [[ ! -s armbian.img.xz ]]; then
  curl -fL --retry 3 -o armbian.img.xz.part -w 'Arquivo final: %{url_effective}\n' "$ORIGEM"
  mv armbian.img.xz.part armbian.img.xz
fi
curl -fsSL --retry 3 -o armbian.sha "$ORIGEM.sha"
esperado=$(grep -oE '^[0-9a-f]{64}' armbian.sha | head -1)
obtido=$(sha256sum armbian.img.xz | cut -d' ' -f1)
echo "SHA-256 esperado: $esperado"
echo "SHA-256 obtido  : $obtido"
[[ -n "$esperado" && "$esperado" == "$obtido" ]] || { echo "SHA-256 NAO confere: download corrompido."; rm -f armbian.img.xz; exit 1; }
echo "Arquivo de referencia: $(sed -E 's/^[0-9a-f]{64} +\*?//' armbian.sha | head -1)"

echo "== 2/5 Descompactando"
rm -f nas.img
xz -dkc armbian.img.xz > nas.img

echo "== 3/5 Montando a particao do sistema"
# particao Linux (ext4) com o sistema: a maior da imagem
read -r inicio setores < <(sfdisk -J nas.img | python3 -c '
import json,sys
p=max(json.load(sys.stdin)["partitiontable"]["partitions"], key=lambda x:x["size"])
print(p["start"], p["size"])')
setor=512
MNT="$TRAB/mnt"; mkdir -p "$MNT"
LOOP=$(losetup -f --show -o $((inicio*setor)) --sizelimit $((setores*setor)) nas.img)
limpar() { umount "$MNT" 2>/dev/null || true; losetup -d "$LOOP" 2>/dev/null || true; }
trap limpar EXIT
mount "$LOOP" "$MNT"
[[ -f "$MNT/etc/os-release" ]] || { echo "Nao achei o sistema dentro da imagem."; exit 1; }
grep -E '^(PRETTY_NAME|VERSION_CODENAME)=' "$MNT/etc/os-release"
grep -q 'VERSION_CODENAME=trixie' "$MNT/etc/os-release" || { echo "A imagem nao e Debian trixie."; exit 1; }
echo "python3 na imagem: $([[ -e $MNT/usr/bin/python3 ]] && echo sim || echo nao - sera instalado no 1o boot)"
echo "avahi na imagem  : $([[ -e $MNT/usr/sbin/avahi-daemon ]] && echo sim || echo nao - sera instalado no 1o boot)"
ls "$MNT/root/.not_logged_in_yet" >/dev/null 2>&1 && echo "assistente de 1o login do Armbian: presente (sera desligado no 1o boot)"

echo "== 4/5 Copiando os arquivos do NAS"
install -D -m 755 "$ARQ/instalar-nas.sh"        "$MNT/usr/local/sbin/instalar-nas.sh"
install -D -m 755 "$ARQ/nas-preparar.sh"        "$MNT/usr/local/sbin/nas-preparar.sh"
install -D -m 755 "$ARQ/nas-assistente.py"      "$MNT/usr/local/lib/nas/nas-assistente.py"
install -D -m 755 "$ARQ/nas-oled.py"            "$MNT/usr/local/lib/nas/nas-oled.py"
for u in nas-preparar.service nas-assistente.service nas-base.service; do
  install -D -m 644 "$ARQ/$u" "$MNT/etc/systemd/system/$u"
  mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
  ln -sf "/etc/systemd/system/$u" "$MNT/etc/systemd/system/multi-user.target.wants/$u"
done
# A tela OLED sobe no inicio do boot (sysinit), antes da rede e dos outros servicos
install -D -m 644 "$ARQ/nas-oled.service" "$MNT/etc/systemd/system/nas-oled.service"
mkdir -p "$MNT/etc/systemd/system/sysinit.target.wants"
ln -sf /etc/systemd/system/nas-oled.service "$MNT/etc/systemd/system/sysinit.target.wants/nas-oled.service"
# nome na rede: nas  ->  http://nas.local:8000
antigo=$(cat "$MNT/etc/hostname" 2>/dev/null || echo "")
echo "$NOME_HOST" > "$MNT/etc/hostname"
if [[ -n "$antigo" ]]; then sed -i "s/\b$antigo\b/$NOME_HOST/g" "$MNT/etc/hosts"; fi
grep -q "\b$NOME_HOST\b" "$MNT/etc/hosts" || echo "127.0.1.1 $NOME_HOST" >> "$MNT/etc/hosts"
mkdir -p "$MNT/etc/apt/apt.conf.d"
echo 'DPkg::Lock::Timeout "900";' > "$MNT/etc/apt/apt.conf.d/90nas-lock"
# Tela OLED opcional (SSD1306 128x64): liga o I2C 7 da ROCK 4B+ (pinos 3 = SDA,
# 5 = SCL) e o /dev/i2c-*. Sem tela, nada muda: o servico nas-oled so encerra.
ENV="$MNT/boot/armbianEnv.txt"
if [[ -f "$ENV" ]] && ! grep -q 'rk3399-i2c7' "$ENV"; then
  [[ -z "$(tail -c1 "$ENV")" ]] || echo >> "$ENV"
  if grep -q '^overlays=' "$ENV"; then sed -i 's/^overlays=\(.*\)$/overlays=\1 rk3399-i2c7/' "$ENV"
  else echo "overlays=rk3399-i2c7" >> "$ENV"; fi
fi
echo "i2c-dev" > "$MNT/etc/modules-load.d/nas-oled.conf"
grep '^overlays=' "$ENV" || echo "AVISO: nao achei $ENV (tela OLED nao sera ativada)"
# Tela OLED desde o boot: o U-Boot do NAS (com i2c, ver arquivos/u-boot) mostra
# "LIGANDO" ~2 s depois de ligar a energia, antes do Linux.
UB="$ARQ/u-boot"
USAR_UBOOT=0
if [[ -s "$UB/idbloader.img" && -s "$UB/u-boot.itb" ]]; then
  USAR_UBOOT=1
  command -v mkimage >/dev/null || { echo "Falta o mkimage (instale o pacote u-boot-tools)"; exit 1; }
  ( cd "$UB" && sha256sum -c SHA256SUMS )
  python3 "$ARQ/nas-oled.py" --quadro-ligando "$MNT/boot/nas-oled-ligando.bin"
  if ! grep -q 'nas-domestico' "$MNT/boot/boot.cmd"; then
    sed -i "/^test -n \"\${distro_bootpart}\"/r $UB/boot-oled.cmd" "$MNT/boot/boot.cmd"
  fi
  grep -q 'nas-oled-ligando.bin' "$MNT/boot/boot.cmd" || { echo "Nao consegui alterar o boot.cmd"; exit 1; }
  mkimage -C none -A arm -T script -d "$MNT/boot/boot.cmd" "$MNT/boot/boot.scr" >/dev/null
  # Impede que uma atualizacao do Armbian troque este U-Boot pelo original (sem i2c)
  python3 - "$MNT/var/lib/dpkg/status" <<'PY'
import re, sys
caminho = sys.argv[1]
blocos = open(caminho, encoding="utf-8").read().split("\n\n")
n = 0
for i, b in enumerate(blocos):
    if re.match(r"Package: linux-u-boot-", b):
        blocos[i] = b.replace("Status: install ok installed", "Status: hold ok installed"); n += 1
open(caminho, "w", encoding="utf-8").write("\n\n".join(blocos))
print("pacote do U-Boot do Armbian travado (hold):", n)
PY
fi
{ echo "nas-imagem gerada em $(date -Is)"; echo "base: $ORIGEM"; echo "sha256 base: $obtido"; } > "$MNT/etc/nas-imagem-versao"
sync
ls -l "$MNT"/usr/local/sbin/instalar-nas.sh "$MNT"/usr/local/sbin/nas-preparar.sh \
      "$MNT"/usr/local/lib/nas/nas-assistente.py "$MNT"/usr/local/lib/nas/nas-oled.py \
      "$MNT"/etc/systemd/system/multi-user.target.wants/nas-* \
      "$MNT"/etc/systemd/system/sysinit.target.wants/nas-oled.service
limpar; trap - EXIT

if (( USAR_UBOOT )); then
  echo "== Gravando o U-Boot do NAS (idbloader no setor 64, u-boot.itb no setor 16384)"
  (( inicio >= 32768 )) || { echo "A particao comeca antes do setor 32768: layout inesperado."; exit 1; }
  (( $(stat -c %s "$UB/idbloader.img") <= (16384 - 64) * 512 )) || { echo "idbloader.img grande demais"; exit 1; }
  (( $(stat -c %s "$UB/u-boot.itb") <= 16384 * 512 )) || { echo "u-boot.itb grande demais"; exit 1; }
  dd if=/dev/zero of=nas.img bs=512 seek=64 count=$((32768 - 64)) conv=notrunc status=none
  dd if="$UB/idbloader.img" of=nas.img bs=512 seek=64 conv=notrunc status=none
  dd if="$UB/u-boot.itb" of=nas.img bs=512 seek=16384 conv=notrunc status=none
fi

echo "== 5/5 Imagem pronta"
mv nas.img "$SAIDA/nas-tcc.img"
( cd "$SAIDA" && sha256sum nas-tcc.img > nas-tcc.img.sha256 )
ls -l "$SAIDA"
echo "Grave $SAIDA/nas-tcc.img no microSD (balenaEtcher, Raspberry Pi Imager ou dd)."
