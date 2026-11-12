#!/bin/bash
# =============================================================================
#  nas-preparar.sh - roda UMA vez, no primeiro boot da imagem do NAS.
#  1) seguranca: o Armbian vem com root/1234 e login automatico no console
#  2) instala o necessario para a pagina do NAS (python3, avahi = nas.local)
# =============================================================================
set -uo pipefail
LOG=/var/log/nas-preparar.log
exec >> "$LOG" 2>&1
echo "===== $(date -Is) nas-preparar ====="
led() { /usr/local/sbin/nas-led "$1" || true; }
led preparando                               # LED pisca rapido: aguarde

# --- 1) Seguranca -------------------------------------------------------------
passwd -l root || true                       # sem login de root por senha
rm -f /root/.not_logged_in_yet               # desliga o assistente do Armbian
for f in /etc/systemd/system/getty@.service.d/override.conf \
         /etc/systemd/system/serial-getty@.service.d/override.conf; do
  if [[ -f "$f" ]] && grep -q autologin "$f"; then rm -f "$f"; echo "removido autologin: $f"; fi
done
systemctl daemon-reload
systemctl restart getty@tty1 2>/dev/null || true
timedatectl set-timezone America/Sao_Paulo 2>/dev/null || true

# Espera ate 15 min pelo apt/dpkg de outros servicos
mkdir -p /etc/apt/apt.conf.d
echo 'DPkg::Lock::Timeout "900";' > /etc/apt/apt.conf.d/90nas-lock

# --- 2) Internet e pacotes ------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
ok=0
for t in $(seq 1 90); do                     # ate ~15 minutos
  if getent hosts deb.debian.org >/dev/null && apt-get update; then ok=1; break; fi
  echo "aguardando internet ($t)..."
  if (( t >= 3 )); then led sem-internet; fi # LED pisca devagar: confira o cabo
  sleep 10
done
if (( ok == 0 )); then
  led sem-internet
  echo "SEM INTERNET: confira o cabo de rede. Tentando de novo no proximo boot."
  exit 1
fi
led preparando
for t in 1 2 3; do
  apt-get install -y python3 avahi-daemon qrencode jq curl ca-certificates && break
  sleep 20
done
systemctl enable --now avahi-daemon || true

mkdir -p /var/lib/nas-instalador
touch /var/lib/nas-instalador/preparado
systemctl start --no-block nas-assistente.service
echo "preparado: abra http://$(hostname).local:8000 no navegador"
