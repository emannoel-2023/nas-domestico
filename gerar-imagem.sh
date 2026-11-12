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
for u in nas-preparar.service nas-assistente.service nas-base.service; do
  install -D -m 644 "$ARQ/$u" "$MNT/etc/systemd/system/$u"
  mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
  ln -sf "/etc/systemd/system/$u" "$MNT/etc/systemd/system/multi-user.target.wants/$u"
done
# nome na rede: nas  ->  http://nas.local:8000
antigo=$(cat "$MNT/etc/hostname" 2>/dev/null || echo "")
echo "$NOME_HOST" > "$MNT/etc/hostname"
if [[ -n "$antigo" ]]; then sed -i "s/\b$antigo\b/$NOME_HOST/g" "$MNT/etc/hosts"; fi
grep -q "\b$NOME_HOST\b" "$MNT/etc/hosts" || echo "127.0.1.1 $NOME_HOST" >> "$MNT/etc/hosts"
mkdir -p "$MNT/etc/apt/apt.conf.d"
echo 'DPkg::Lock::Timeout "900";' > "$MNT/etc/apt/apt.conf.d/90nas-lock"
{ echo "nas-imagem gerada em $(date -Is)"; echo "base: $ORIGEM"; echo "sha256 base: $obtido"; } > "$MNT/etc/nas-imagem-versao"
sync
ls -l "$MNT"/usr/local/sbin/instalar-nas.sh "$MNT"/usr/local/sbin/nas-preparar.sh \
      "$MNT"/usr/local/lib/nas/nas-assistente.py "$MNT"/etc/systemd/system/multi-user.target.wants/nas-*
limpar; trap - EXIT

echo "== 5/5 Imagem pronta"
mv nas.img "$SAIDA/nas-tcc.img"
( cd "$SAIDA" && sha256sum nas-tcc.img > nas-tcc.img.sha256 )
ls -l "$SAIDA"
echo "Grave $SAIDA/nas-tcc.img no microSD (balenaEtcher, Raspberry Pi Imager ou dd)."
