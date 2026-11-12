#!/usr/bin/env bash
# =============================================================================
#  instalar-nas.sh v2 - NAS domestico: OpenMediaVault 8 + SMB + Nextcloud
#                       (Docker) + Tailscale, para SBC arm64 com Armbian trixie
#
#  Modos:
#    sudo bash instalar-nas.sh               instalacao pelo terminal (pergunta
#                                            usuario/senha e instala tudo)
#    instalar-nas.sh --base                  instalacao sem perguntas (usada pela
#                                            pagina de configuracao no navegador)
#    instalar-nas.sh --organizar             procura SSDs e organiza (timer, 30 s)
#    instalar-nas.sh --formatar /dev/sdX     apaga um disco com dados e o usa
#    instalar-nas.sh --verificar             confere a instalacao
#
#  Discos: o NAS funciona sem SSD. Quando um SSD e conectado:
#    - SSD vazio (sem particoes)        -> preparado automaticamente
#    - SSD formatado e montado pelo OMV -> usado automaticamente
#    - SSD com dados                    -> NUNCA e apagado sozinho; o usuario
#                                          decide (pagina do NAS ou painel do OMV)
#  O primeiro disco (ou os dois primeiros, se conectados juntos) recebe os
#  arquivos (SMB) e o Nextcloud. Discos seguintes viram pastas extras (disco2...).
# =============================================================================
set -Eeuo pipefail
shopt -s inherit_errexit   # erros dentro de $(...) tambem param o script

VERSAO="2.1"
LOG=/var/log/nas-instalador.log
ESTADO_DIR=/var/lib/nas-instalador
ESTADO="$ESTADO_DIR/etapas"
PROGRESSO="$ESTADO_DIR/progresso.json"
CONF=/etc/nas-instalador.conf
SENHA_ARQ=/etc/nas-instalador.senha
RUN_DIR=/run/nas
DISCOS_JSON="$RUN_DIR/discos.json"
VISTOS="$RUN_DIR/vistos"
LOCK=/run/nas-instalador.lock
CRED=/root/nas-credenciais.txt
NEW_UUID_PADRAO="fa4b1c66-ef79-11e5-87a0-0002b3a176b4"   # OMV_CONFIGOBJECT_NEW_UUID
NC_IMAGE="${NC_IMAGE:-nextcloud:apache}"
NC_PORTA=8081
ESTAVEL_SEG="${ESTAVEL_SEG:-45}"     # espera o disco "assentar" antes de usar
ETAPA_ATUAL=""

# -----------------------------------------------------------------------------
# Mensagens
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_AZ=$'\e[1;34m'; C_VD=$'\e[1;32m'; C_AM=$'\e[1;33m'; C_VM=$'\e[1;31m'; C_0=$'\e[0m'
else
  C_AZ=""; C_VD=""; C_AM=""; C_VM=""; C_0=""
fi
titulo() { echo; echo "${C_AZ}==== $* ====${C_0}"; }
info()   { echo "  $*"; }
ok()     { echo "${C_VD}  [OK]${C_0} $*"; }
aviso()  { echo "${C_AM}  [ATENCAO]${C_0} $*"; }
erro()   { echo "${C_VM}  [ERRO]${C_0} $*" >&2; }
morrer() { erro "$*"; prog_erro "$*"; erro "Log completo: $LOG"; exit 1; }

falha_inesperada() {
  erro "Falha na linha $1: $2"
  prog_erro "Falha inesperada (linha $1). Veja o log."
  erro "Rode de novo: o instalador continua de onde parou. Log: $LOG"
}
trap 'falha_inesperada $LINENO "$BASH_COMMAND"' ERR

TTY=/dev/tty
perguntar() {   # perguntar VAR "texto" "padrao"
  local __var=$1 __txt=$2 __pad=${3:-} __resp
  if [[ -n "${!__var:-}" ]]; then return 0; fi
  read -r -p "  $__txt${__pad:+ [$__pad]}: " __resp < "$TTY"
  printf -v "$__var" '%s' "${__resp:-$__pad}"
}
sim_ou_nao() {  # sim_ou_nao "texto" s|n
  local __r
  read -r -p "  $1 [${2^^}/$( [[ $2 == s ]] && echo n || echo s )]: " __r < "$TTY"
  __r=${__r:-$2}; [[ "${__r,,}" == s* || "${__r,,}" == y* ]]
}
senha_valida() {  # imprime o problema, ou nada se estiver ok
  local s=$1
  if (( ${#s} < 8 )); then echo "Use pelo menos 8 caracteres."; return; fi
  if [[ "$s" == *"'"* || "$s" == *'"'* || "$s" == *'\'* || "$s" == *$'\n'* || "$s" == *:* ]]; then
    echo "Nao use aspas, barra invertida nem dois-pontos na senha."; return
  fi
}
usuario_valido() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || { echo "Use so letras minusculas, numeros, - ou _."; return; }
  [[ "$1" != admin && "$1" != root && "$1" != www-data ]] || echo "Esse nome e reservado; escolha outro."
}
ler_senha() {   # ler_senha VAR "texto"
  local __var=$1 __a __b __p
  while true; do
    read -r -s -p "  $2: " __a < "$TTY"; echo
    read -r -s -p "  Repita a senha: " __b < "$TTY"; echo
    [[ "$__a" == "$__b" ]] || { aviso "As senhas nao conferem."; continue; }
    __p=$(senha_valida "$__a"); [[ -z "$__p" ]] || { aviso "$__p"; continue; }
    printf -v "$__var" '%s' "$__a"; return 0
  done
}
gerar_senha() { openssl rand -hex 20; }

# -----------------------------------------------------------------------------
# Estado, configuracao e progresso (lido pela pagina do navegador)
# -----------------------------------------------------------------------------
feita()   { [[ -f "$ESTADO" ]] && grep -qx "$1" "$ESTADO"; }
marcar()  { echo "$1" >> "$ESTADO"; }
salvar() {      # salvar CHAVE valor
  touch "$CONF"; chmod 600 "$CONF"
  sed -i "/^$1=/d" "$CONF"
  printf "%s=%q\n" "$1" "$2" >> "$CONF"
}
# shellcheck disable=SC1090
carregar() { if [[ -f "$CONF" ]]; then . "$CONF"; fi; }
senha_salva() { [[ -r "$SENHA_ARQ" ]] && cat "$SENHA_ARQ"; }

prog_set() {    # prog_set chave valor  (valor texto)
  command -v jq >/dev/null 2>&1 || return 0
  mkdir -p "$ESTADO_DIR"
  [[ -s "$PROGRESSO" ]] || echo '{"etapas":{},"nextcloud":"aguardando_disco"}' > "$PROGRESSO"
  local tmp; tmp=$(mktemp "$ESTADO_DIR/.prog.XXXX")
  jq --arg k "$1" --arg v "$2" '.[$k]=$v | .atualizado=(now|floor)' "$PROGRESSO" > "$tmp" && mv "$tmp" "$PROGRESSO"
  chmod 644 "$PROGRESSO"
}
prog_etapa() {  # prog_etapa id status(andamento|ok|erro)
  command -v jq >/dev/null 2>&1 || return 0
  mkdir -p "$ESTADO_DIR"
  [[ -s "$PROGRESSO" ]] || echo '{"etapas":{},"nextcloud":"aguardando_disco"}' > "$PROGRESSO"
  local tmp; tmp=$(mktemp "$ESTADO_DIR/.prog.XXXX")
  jq --arg k "$1" --arg v "$2" '.etapas[$k]=$v | .atualizado=(now|floor)' "$PROGRESSO" > "$tmp" && mv "$tmp" "$PROGRESSO"
  chmod 644 "$PROGRESSO"
}
prog_erro() {
  [[ -n "$ETAPA_ATUAL" ]] && prog_etapa "$ETAPA_ATUAL" erro
  prog_set erro "$1"
}

etapa() {       # etapa id funcao "descricao"
  if feita "$1"; then prog_etapa "$1" ok; return 0; fi
  titulo "$3"
  ETAPA_ATUAL=$1
  prog_set erro ""
  prog_etapa "$1" andamento
  "$2"
  marcar "$1"
  prog_etapa "$1" ok
  ETAPA_ATUAL=""
  ok "$3"
}

iniciar_log() {
  mkdir -p "$ESTADO_DIR" "$RUN_DIR"
  exec > >(tee -a "$LOG") 2>&1
  echo "----- $(date -Is) instalar-nas.sh v$VERSAO $* -----"
}

verificar_sistema() {
  local arq; arq=$(dpkg --print-architecture)
  [[ "$arq" == arm64 || "$arq" == amd64 ]] || morrer "Arquitetura $arq nao suportada (precisa ser arm64 ou amd64)."
  local cod; cod=$(. /etc/os-release; echo "${VERSION_CODENAME:-}")
  [[ "$cod" == trixie ]] || morrer "Precisa de Debian 13 'trixie' (o OpenMediaVault 8 so roda nele). Encontrado: $cod"
  local t
  for t in 1 2 3 4 5 6 7 8 9 10 11 12; do
    curl -fsS --max-time 10 -o /dev/null https://deb.debian.org/ && break
    (( t < 12 )) || morrer "Sem internet. Confira o cabo de rede."
    sleep 10
  done
  local livre; livre=$(df -Pm / | awk 'NR==2{print $4}')
  (( livre > 4000 )) || morrer "Pouco espaco livre no microSD (${livre} MB). Use um cartao de 16 GB ou mais."
}

# =============================================================================
# INSTALACAO BASE (nao precisa de SSD)
# =============================================================================
pacotes_base() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl ca-certificates gnupg jq parted e2fsprogs openssl lsof \
                     avahi-daemon qrencode python3
  timedatectl set-timezone America/Sao_Paulo 2>/dev/null || true
}

instalar_omv() {
  if dpkg -s openmediavault >/dev/null 2>&1; then info "OpenMediaVault ja instalado."; return 0; fi
  info "Isto demora (10 a 30 minutos). A rede NAO sera alterada (-n)."
  curl -fsSL -o /root/omv-install.sh \
    https://github.com/OpenMediaVault-Plugin-Developers/installScript/raw/master/install
  bash /root/omv-install.sh -n || true
  dpkg -s openmediavault >/dev/null 2>&1 || morrer "A instalacao do OpenMediaVault falhou. Veja /root/omv_install.log"
}

omv_new_uuid() {
  local u=""
  # shellcheck disable=SC1091
  [[ -f /etc/default/openmediavault ]] && u=$(. /etc/default/openmediavault; echo "${OMV_CONFIGOBJECT_NEW_UUID:-}")
  echo "${u:-$NEW_UUID_PADRAO}"
}
omv_set() { jq -c . | omv-confdbadm update "$1" - >/dev/null; }   # JSON no stdin

configurar_usuario() {
  carregar
  local senha; senha=$(senha_salva) || true
  [[ -n "$senha" ]] || morrer "Senha do usuario nao encontrada ($SENHA_ARQ)."
  if id "$NAS_USUARIO" >/dev/null 2>&1; then
    usermod -aG users "$NAS_USUARIO"
    info "Usuario $NAS_USUARIO ja existe; a senha de login do Linux nao foi alterada."
  else
    useradd -m -s /bin/bash -G users,sudo "$NAS_USUARIO"
    echo "$NAS_USUARIO:$senha" | chpasswd
    info "Usuario $NAS_USUARIO criado (com sudo)."
  fi
  getent group _ssh >/dev/null && usermod -aG _ssh "$NAS_USUARIO"
  # Administrador no painel do OMV com o proprio usuario (sem isso ele entra
  # no painel mas nao tem permissao nenhuma; so o "admin" teria)
  if getent group openmediavault-admin >/dev/null; then
    usermod -aG openmediavault-admin "$NAS_USUARIO"
  else
    aviso "Grupo openmediavault-admin nao encontrado; use o usuario admin no painel do OMV."
  fi
  printf '%s\n%s\n' "$senha" "$senha" | smbpasswd -s -a "$NAS_USUARIO"
  smbpasswd -e "$NAS_USUARIO" >/dev/null
  # Painel do OMV: usuario admin com a mesma senha (a padrao seria "openmediavault")
  if id admin >/dev/null 2>&1; then
    echo "admin:$senha" | chpasswd
  else
    aviso "Usuario admin do OMV nao encontrado; a senha do painel continua a padrao."
  fi
  omv-confdbadm read conf.service.smb | jq '.enable=true | .minprotocol="SMB2"' | omv_set conf.service.smb
  omv-salt deploy run samba
}

instalar_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    apt-get update
    if ! apt-cache policy docker-ce | grep -q 'Candidate: [0-9]'; then
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
      cat > /etc/apt/sources.list.d/docker-nas.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
      if ! apt-get update; then
        rm -f /etc/apt/sources.list.d/docker-nas.sources
        morrer "Conflito no repositorio do Docker. Ative o Docker pelo omv-extras no painel do OMV e tente de novo."
      fi
    fi
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  fi
  systemctl enable --now docker
  docker compose version >/dev/null || morrer "docker compose nao esta disponivel."
}

instalar_tailscale() {
  carregar
  [[ "${NAS_TAILSCALE:-s}" == s ]] || { info "Tailscale pulado."; return 0; }
  command -v tailscale >/dev/null 2>&1 || curl -fsSL https://tailscale.com/install.sh | sh
  systemctl enable --now tailscaled
  # O login e feito depois: pela pagina do NAS (botao) ou pelo terminal.
}

habilitar_organizador() {
  cat > /etc/systemd/system/nas-organizador.service <<'EOF'
[Unit]
Description=NAS: detecta e organiza SSDs conectados
After=openmediavault-engined.service docker.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/instalar-nas.sh --organizar
EOF
  cat > /etc/systemd/system/nas-organizador.timer <<'EOF'
[Unit]
Description=NAS: procura SSDs a cada 30 segundos
[Timer]
OnBootSec=40s
OnUnitActiveSec=30s
AccuracySec=5s
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now nas-organizador.timer
}

modo_base() {
  verificar_sistema
  etapa base      pacotes_base         "Pacotes basicos"
  etapa omv       instalar_omv         "OpenMediaVault"
  etapa usuario   configurar_usuario   "Usuario, senha e SMB"
  etapa docker    instalar_docker      "Docker"
  etapa tailscale instalar_tailscale   "Tailscale"
  [[ -x /usr/local/sbin/instalar-nas.sh ]] || install -m 755 "$0" /usr/local/sbin/instalar-nas.sh
  habilitar_organizador
  touch "$ESTADO_DIR/base-ok"
  prog_set fase "pronto"
  ok "Base instalada. Agora e so conectar um SSD."
}

# =============================================================================
# DISCOS
# =============================================================================
disco_do_sistema() {
  local src; src=$(findmnt -no SOURCE /)
  lsblk -no PKNAME "$src" 2>/dev/null | head -1
}
listar_discos() {   # (TAB) /dev/sdX bytes tamanho transporte modelo  -- maior primeiro
  local raiz; raiz=$(disco_do_sistema)
  lsblk -J -b -d -p -o NAME,SIZE,TYPE,TRAN,MODEL \
    | jq -r '.blockdevices[] | select(.type=="disk") | [.name, (.size|tostring), (.tran // "-"), (.model // "")] | @tsv' \
    | while IFS=$'\t' read -r nome bytes tran modelo; do
    [[ "$nome" == /dev/mmcblk* || "$nome" == /dev/zram* || "$nome" == /dev/loop* ]] && continue
    [[ -n "$raiz" && "$nome" == "/dev/$raiz" ]] && continue
    (( bytes > 0 )) || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$nome" "$bytes" "$(numfmt --to=si --suffix=B "$bytes")" "$tran" "$modelo"
  done | sort -t$'\t' -k2,2nr
}
disco_vazio() {     # sem tabela de particoes, sem particoes, sem assinatura
  local d=$1
  (( $(lsblk -nr -o NAME "$d" | wc -l) == 1 )) || return 1
  [[ -z "$(lsblk -dnro FSTYPE,PTTYPE "$d" | tr -d ' ')" ]] || return 1
  ! blkid -p "$d" >/dev/null 2>&1
}
disco_montado() { lsblk -nro MOUNTPOINTS "$1" | grep -q .; }

formatar_disco() {   # formatar_disco /dev/sdX ROTULO  -> imprime UUID
  local d=$1 rotulo=$2 part uuid
  info "Formatando $d como ext4 ($rotulo)..." >&2
  wipefs -a "$d" >&2
  parted -s "$d" mklabel gpt mkpart "$rotulo" ext4 1MiB 100% >&2
  udevadm settle; sleep 2
  part=$(lsblk -lnpo NAME,TYPE "$d" | awk '$2=="part"{print $1; exit}')
  [[ -b "$part" ]] || morrer "Particao nao apareceu em $d."
  mkfs.ext4 -F -m 1 -L "$rotulo" "$part" >&2
  udevadm settle; sleep 1
  uuid=$(blkid -s UUID -o value "$part")
  [[ -n "$uuid" ]] || morrer "Nao consegui ler o UUID de $part."
  echo "$uuid"
}

registrar_fs() {    # registra o ext4 no OMV e monta
  local u=$1 fs="/dev/disk/by-uuid/$1" dir="/srv/dev-disk-by-uuid-$1"
  mkdir -p "$dir"
  if ! omv-confdbadm read conf.system.filesystem.mountpoint | jq -e --arg f "$fs" 'any(.[]; .fsname==$f)' >/dev/null; then
    jq -n --arg uuid "$(omv_new_uuid)" --arg fs "$fs" --arg dir "$dir" '{
      uuid:$uuid, fsname:$fs, dir:$dir, type:"ext4",
      opts:"defaults,nofail,user_xattr,usrquota,grpquota,acl",
      freq:0, passno:2, hidden:false, usagewarnthreshold:85, comment:"NAS"}' \
    | omv_set conf.system.filesystem.mountpoint
  fi
  omv-salt deploy run fstab >/dev/null
  systemctl daemon-reload
  mountpoint -q "$dir" || mount "$dir"
  mountpoint -q "$dir" || morrer "Nao consegui montar $dir."
  ok "Montado: $dir"
}

fs_omv_montados() { # UUIDs dos sistemas de arquivos do OMV montados em /srv
  omv-confdbadm read conf.system.filesystem.mountpoint 2>/dev/null \
    | jq -r '.[] | select((.hidden|tostring)!="true" and (.dir|startswith("/srv/"))) | [.fsname, .dir] | @tsv' \
    | while IFS=$'\t' read -r fsname dir; do
      mountpoint -q "$dir" || continue
      local u="${fsname#/dev/disk/by-uuid/}"
      [[ "$u" == "$fsname" ]] && u=$(blkid -s UUID -o value "$(readlink -f "$fsname")" 2>/dev/null || true)
      [[ -n "$u" && "$dir" == "/srv/dev-disk-by-uuid-$u" ]] && echo "$u"
    done
}
adotado() {
  carregar
  [[ " ${UUID_DADOS:-} ${UUID_NUVEM:-} ${EXTRAS:-} " == *" $1 "* ]]
}

mntent_de() {
  omv-confdbadm read conf.system.filesystem.mountpoint \
    | jq -r --arg f "/dev/disk/by-uuid/$1" '.[] | select(.fsname==$f) | .uuid'
}
pasta_omv() {       # pasta_omv nome uuid_fs -> imprime uuid da pasta compartilhada
  local nome=$1 ref; ref=$(mntent_de "$2")
  [[ -n "$ref" ]] || morrer "Disco $2 nao registrado no OMV."
  mkdir -p "/srv/dev-disk-by-uuid-$2/$nome"
  if ! omv-confdbadm read conf.system.sharedfolder | jq -e --arg n "$nome" 'any(.[]; .name==$n)' >/dev/null; then
    jq -n --arg uuid "$(omv_new_uuid)" --arg n "$nome" --arg ref "$ref" --arg user "$NAS_USUARIO" '{
      uuid:$uuid, name:$n, comment:"", mntentref:$ref, reldirpath:($n + "/"),
      privileges:{privilege:[{type:"user", name:$user, perms:7}]}}' \
    | omv_set conf.system.sharedfolder
  fi
  omv-confdbadm read conf.system.sharedfolder | jq -r --arg n "$nome" '.[] | select(.name==$n) | .uuid'
}
compartilhar_smb() {  # compartilhar_smb nome uuid_fs "comentario"
  carregar
  local sf; sf=$(pasta_omv "$1" "$2")
  local d="/srv/dev-disk-by-uuid-$2/$1"
  chown "$NAS_USUARIO:users" "$d"; chmod 2775 "$d"
  if ! omv-confdbadm read conf.service.smb.share | jq -e --arg r "$sf" 'any(.[]; .sharedfolderref==$r)' >/dev/null; then
    jq -n --arg uuid "$(omv_new_uuid)" --arg r "$sf" --arg c "$3" '{
      uuid:$uuid, enable:true, sharedfolderref:$r, comment:$c,
      guest:"no", readonly:false, browseable:true}' \
    | omv_set conf.service.smb.share
  fi
  omv-salt deploy run samba >/dev/null
  ok "Compartilhamento SMB: $1"
}

# -----------------------------------------------------------------------------
# Nextcloud (Docker Compose)
# -----------------------------------------------------------------------------
ip_lan() { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'; }
ts_ip() { command -v tailscale >/dev/null 2>&1 && tailscale ip -4 2>/dev/null | head -1; }

nextcloud() {
  carregar
  local senha; senha=$(senha_salva) || true
  [[ -n "$senha" ]] || morrer "Senha do usuario nao encontrada para criar o Nextcloud."
  local base="/srv/dev-disk-by-uuid-$UUID_NUVEM"
  local cdir="$base/compose/nextcloud"
  pasta_omv appdata "$UUID_NUVEM" >/dev/null
  pasta_omv compose "$UUID_NUVEM" >/dev/null
  pasta_omv nextcloud_data "$UUID_NUVEM" >/dev/null
  pasta_omv backup "$UUID_NUVEM" >/dev/null
  mkdir -p "$base/appdata/nextcloud" "$base/appdata/mariadb" "$cdir"
  chown 33:33 "$base/appdata/nextcloud" "$base/nextcloud_data"
  chmod 770 "$base/nextcloud_data"
  chmod 700 "$cdir"

  # Licao do prototipo: se o SSD nao montar no boot, o Docker NAO pode subir,
  # senao o Nextcloud grava no microSD.
  mkdir -p /etc/systemd/system/docker.service.d
  printf '[Unit]\nRequiresMountsFor=%s\n' "$base" > /etc/systemd/system/docker.service.d/nas-discos.conf
  systemctl daemon-reload

  if [[ ! -f "$cdir/db.env" ]]; then
    local root_pw db_pw ipl hn tsi dominios
    root_pw=$(gerar_senha); db_pw=$(gerar_senha); ipl=$(ip_lan); hn=$(hostname)
    dominios="localhost $ipl $ipl:$NC_PORTA $hn $hn:$NC_PORTA $hn.local $hn.local:$NC_PORTA"
    tsi=$(ts_ip || true); [[ -n "$tsi" ]] && dominios+=" $tsi $tsi:$NC_PORTA"
    ( umask 077
      cat > "$cdir/db.env" <<EOF
MYSQL_ROOT_PASSWORD='$root_pw'
MYSQL_DATABASE='nextcloud'
MYSQL_USER='nextcloud'
MYSQL_PASSWORD='$db_pw'
EOF
      cat > "$cdir/nextcloud.env" <<EOF
MYSQL_HOST='db'
MYSQL_DATABASE='nextcloud'
MYSQL_USER='nextcloud'
MYSQL_PASSWORD='$db_pw'
REDIS_HOST='redis'
NEXTCLOUD_ADMIN_USER='$NAS_USUARIO'
NEXTCLOUD_ADMIN_PASSWORD='$senha'
NEXTCLOUD_TRUSTED_DOMAINS='$dominios'
PHP_UPLOAD_LIMIT='16G'
PHP_MEMORY_LIMIT='512M'
EOF
    )
  fi

  cat > "$cdir/compose.yml" <<EOF
# Gerado por instalar-nas.sh v$VERSAO
name: nextcloud
services:
  db:
    image: mariadb:11
    container_name: nextcloud_db
    restart: unless-stopped
    command: --transaction-isolation=READ-COMMITTED
    env_file: db.env
    volumes:
      - $base/appdata/mariadb:/var/lib/mysql

  redis:
    image: redis:7-alpine
    container_name: nextcloud_redis
    restart: unless-stopped

  app:
    image: $NC_IMAGE
    container_name: nextcloud
    restart: unless-stopped
    depends_on: [db, redis]
    ports:
      - "$NC_PORTA:80"
    env_file: nextcloud.env
    volumes:
      - $base/appdata/nextcloud:/var/www/html
      - $base/nextcloud_data:/var/www/html/data
EOF
  chmod 600 "$cdir/compose.yml"

  prog_set nextcloud instalando
  info "Baixando as imagens e iniciando o Nextcloud (pode levar varios minutos)..."
  docker compose -f "$cdir/compose.yml" up -d

  local t=0
  until docker exec -u www-data nextcloud php occ status --output=json 2>/dev/null | jq -e '.installed==true' >/dev/null; do
    sleep 10; t=$((t+10))
    (( t % 60 == 0 )) && info "... aguardando o Nextcloud (${t}s)"
    (( t < 1500 )) || morrer "O Nextcloud nao terminou de instalar em 25 min. Veja: docker logs nextcloud"
  done
  local occ=(docker exec -u www-data nextcloud php occ)
  "${occ[@]}" background:cron
  "${occ[@]}" config:system:set default_phone_region --value=BR
  "${occ[@]}" config:system:set maintenance_window_start --type=integer --value=4
  "${occ[@]}" db:add-missing-indices || true
  [[ -n "${tsi:-}" ]] && salvar TS_DOMINIO "$tsi"
  prog_set nextcloud pronto
  ok "Nextcloud pronto em http://$(ip_lan):$NC_PORTA"
}

# Inclui o IP/nome do Tailscale nos dominios confiaveis do Nextcloud
# (o login no Tailscale pode acontecer depois do Nextcloud ser criado).
dominios_tailscale() {
  carregar
  local tsi; tsi=$(ts_ip || true)
  [[ -n "$tsi" && "$tsi" != "${TS_DOMINIO:-}" ]] || return 0
  docker ps --format '{{.Names}}' | grep -qx nextcloud || return 0
  local occ=(docker exec -u www-data nextcloud php occ) atuais i novo tsdns
  atuais=$("${occ[@]}" config:system:get trusted_domains 2>/dev/null) || return 0
  i=$(grep -c . <<< "$atuais" || true)
  tsdns=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // ""' | sed 's/\.$//')
  for novo in "$tsi" "$tsi:$NC_PORTA" "$tsdns" "${tsdns:+$tsdns:$NC_PORTA}"; do
    [[ -n "$novo" ]] || continue
    grep -qx "$novo" <<< "$atuais" && continue
    "${occ[@]}" config:system:set trusted_domains "$i" --value="$novo" >/dev/null
    i=$((i+1))
  done
  salvar TS_DOMINIO "$tsi"
  info "Tailscale incluido nos enderecos do Nextcloud ($tsi)."
}

# -----------------------------------------------------------------------------
# Cron do Nextcloud, watchdog do SSD USB e backup de configuracao
# -----------------------------------------------------------------------------
manutencao() {
  carregar
  local base="/srv/dev-disk-by-uuid-$UUID_NUVEM"
  local destinos="$base"
  [[ "$UUID_DADOS" != "$UUID_NUVEM" ]] && destinos+=" /srv/dev-disk-by-uuid-$UUID_DADOS"

  cat > /etc/systemd/system/nextcloud-cron.service <<'EOF'
[Unit]
Description=Tarefas em segundo plano do Nextcloud
After=docker.service
Requires=docker.service
[Service]
Type=oneshot
ExecStart=/usr/bin/docker exec -u www-data nextcloud php -f /var/www/html/cron.php
EOF
  cat > /etc/systemd/system/nextcloud-cron.timer <<'EOF'
[Unit]
Description=Executa o cron do Nextcloud a cada 5 minutos
[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
EOF

  cat > /usr/local/sbin/nextcloud-watchdog.sh <<EOF
#!/bin/sh
# Reinicia o Nextcloud quando o SSD USB cai e volta: os containers ficam
# presos na montagem antiga e passam a dar "Input/output error".
DISK=$base
[ "\$(docker inspect -f '{{.State.Running}}' nextcloud 2>/dev/null)" = "true" ] || exit 0
docker exec nextcloud test -r /var/www/html/version.php 2>/dev/null && exit 0
mountpoint -q "\$DISK" && [ -r "\$DISK/appdata/nextcloud/version.php" ] || exit 0
logger -t nextcloud-watchdog "Nextcloud sem acesso ao disco; reiniciando containers"
docker restart nextcloud_db nextcloud_redis nextcloud
EOF
  chmod 755 /usr/local/sbin/nextcloud-watchdog.sh
  cat > /etc/systemd/system/nextcloud-watchdog.service <<'EOF'
[Unit]
Description=Reinicia o Nextcloud se o disco USB reconectar
After=docker.service
Requires=docker.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nextcloud-watchdog.sh
EOF
  cat > /etc/systemd/system/nextcloud-watchdog.timer <<'EOF'
[Unit]
Description=Verifica o Nextcloud a cada minuto
[Timer]
OnBootSec=3min
OnUnitActiveSec=1min
[Install]
WantedBy=timers.target
EOF

  cat > /usr/local/sbin/nas-config-backup.sh <<EOF
#!/bin/bash
set -euo pipefail
DESTINOS="$destinos"
CDIR="$base/compose/nextcloud"
NCCONFIG="$base/appdata/nextcloud/config/config.php"

for d in \$DESTINOS; do
  mountpoint -q "\$d" || { echo "SSD \$d nao montado; backup cancelado" >&2; exit 1; }
done

STAMP="\$(date +%Y-%m-%d_%H-%M-%S)"
WORK="\$(mktemp -d)"; trap 'rm -rf "\$WORK"' EXIT
PKG="\$WORK/nas-config-\$STAMP"; mkdir -p "\$PKG"

cp /etc/openmediavault/config.xml "\$PKG/omv-config.xml"
cp /etc/fstab "\$PKG/fstab"
cp /etc/nas-instalador.conf "\$PKG/nas-instalador.conf"
cp "\$CDIR/compose.yml" "\$CDIR/db.env" "\$CDIR/nextcloud.env" "\$PKG/"
cp "\$NCCONFIG" "\$PKG/nextcloud-config.php"
docker exec nextcloud_db sh -c 'mariadb-dump -u root -p"\$MYSQL_ROOT_PASSWORD" --all-databases --single-transaction' > "\$PKG/mariadb-all-databases.sql"
lsblk -f > "\$PKG/lsblk.txt"; findmnt > "\$PKG/findmnt.txt"
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' > "\$PKG/docker-containers.txt"
{ echo "Data: \$(date -Is)"; echo "Host: \$(hostname)"; echo "Kernel: \$(uname -r)"; tailscale status 2>/dev/null || true; } > "\$PKG/manifesto.txt"
( cd "\$PKG" && sha256sum * > SHA256SUMS )

ARQ="\$WORK/nas-config-\$STAMP.tar.gz"
tar -C "\$WORK" -czf "\$ARQ" "nas-config-\$STAMP"
chmod 600 "\$ARQ"
for d in \$DESTINOS; do
  mkdir -p "\$d/.nas-config-backup"; chmod 700 "\$d/.nas-config-backup"
  cp "\$ARQ" "\$d/.nas-config-backup/"
  ls -1t "\$d"/.nas-config-backup/nas-config-*.tar.gz | tail -n +7 | xargs -r rm --
  echo "Backup: \$d/.nas-config-backup/\$(basename "\$ARQ")"
done
EOF
  chmod 700 /usr/local/sbin/nas-config-backup.sh
  cat > /etc/systemd/system/nas-config-backup.service <<'EOF'
[Unit]
Description=Backup de configuracao do NAS
After=docker.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nas-config-backup.sh
EOF
  cat > /etc/systemd/system/nas-config-backup.timer <<'EOF'
[Unit]
Description=Executa backup de configuracao do NAS a cada 10 dias
[Timer]
OnBootSec=10min
OnUnitActiveSec=10d
Persistent=true
[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now nextcloud-cron.timer nextcloud-watchdog.timer nas-config-backup.timer
  /usr/local/sbin/nas-config-backup.sh || aviso "O primeiro backup falhou; o timer tenta de novo."
}

# -----------------------------------------------------------------------------
# Organizador: chamado a cada 30 s
# -----------------------------------------------------------------------------
configurar_principal() {  # configurar_principal uuid_dados uuid_nuvem
  salvar UUID_DADOS "$1"; salvar UUID_NUVEM "$2"
  carregar
  if [[ "$1" == "$2" ]]; then
    info "Disco principal: arquivos e Nextcloud no mesmo SSD ($1)."
  else
    info "Arquivos (SMB) em $1; Nextcloud em $2."
  fi
  compartilhar_smb dados "$UUID_DADOS" "Arquivos do NAS"
}

adicionar_extra() {
  carregar
  local -a ex; read -r -a ex <<< "${EXTRAS:-}"
  local n=$(( 2 + ${#ex[@]} ))
  if [[ "$UUID_DADOS" != "$UUID_NUVEM" ]]; then n=$((n+1)); fi
  compartilhar_smb "disco$n" "$1" "Disco extra $n"
  salvar EXTRAS "${EXTRAS:+$EXTRAS }$1"
}

atualizar_vistos() {    # guarda quando cada disco apareceu
  local agora d; agora=$(date +%s)
  touch "$VISTOS"
  local novos; novos=$(mktemp "$RUN_DIR/.vistos.XXXX")
  while IFS=$'\t' read -r d _; do
    [[ -n "$d" ]] || continue
    local t; t=$(awk -v d="$d" '$1==d{print $2}' "$VISTOS")
    echo "$d ${t:-$agora}" >> "$novos"
  done < <(listar_discos)
  mv "$novos" "$VISTOS"
}
estavel() { local t; t=$(awk -v d="$1" '$1==d{print $2}' "$VISTOS"); [[ -n "$t" ]] && (( $(date +%s) - t >= ESTAVEL_SEG )); }

escrever_discos_json() {
  carregar
  local d bytes tam tran modelo estado papel u linhas=""
  while IFS=$'\t' read -r d bytes tam tran modelo; do
    [[ -n "$d" ]] || continue
    estado="com_dados"; papel="Nao usado pelo NAS"
    u=$(lsblk -nro UUID,MOUNTPOINTS "$d" | awk '$2 ~ /^\/srv\/dev-disk-by-uuid-/ {print $1; exit}')
    if [[ -n "$u" ]]; then
      if [[ "$u" == "${UUID_DADOS:-}" && "$u" == "${UUID_NUVEM:-}" ]]; then estado=em_uso; papel="Arquivos (SMB) e Nextcloud"
      elif [[ "$u" == "${UUID_DADOS:-}" ]]; then estado=em_uso; papel="Arquivos (SMB)"
      elif [[ "$u" == "${UUID_NUVEM:-}" ]]; then estado=em_uso; papel="Nextcloud"
      elif [[ " ${EXTRAS:-} " == *" $u "* ]]; then estado=em_uso; papel="Pasta extra"
      else estado=preparando; papel="Sendo organizado"; fi
    elif disco_vazio "$d"; then
      estado=vazio; papel="Sera preparado automaticamente"
    elif disco_montado "$d"; then
      estado=em_uso_outro; papel="Montado fora do NAS"
    fi
    linhas+="$d"$'\t'"$tam"$'\t'"$modelo"$'\t'"$tran"$'\t'"$estado"$'\t'"$papel"$'\n'
  done < <(listar_discos)
  mkdir -p "$RUN_DIR"
  printf '%s' "$linhas" | jq -Rn '[inputs | select(length>0) | split("\t") |
      {dev:.[0], tamanho:.[1], modelo:.[2], conexao:.[3], estado:.[4], papel:.[5]}]' > "$DISCOS_JSON.tmp"
  mv "$DISCOS_JSON.tmp" "$DISCOS_JSON"; chmod 644 "$DISCOS_JSON"
}

organizar_interno() {
  carregar
  atualizar_vistos
  local d u novos=() vazios=()

  # 1) SSDs vazios e estaveis: prepara automaticamente
  while IFS=$'\t' read -r d _; do
    [[ -n "$d" ]] || continue
    disco_vazio "$d" && estavel "$d" && vazios+=("$d")
  done < <(listar_discos)
  local n=0
  for d in "${vazios[@]}"; do
    n=$((n+1))
    titulo "SSD novo encontrado: $d"
    u=$(formatar_disco "$d" "NAS_$(date +%H%M%S)_$n")
    registrar_fs "$u"
  done

  # 2) Sistemas de arquivos montados pelo OMV e ainda nao usados pelo NAS
  while read -r u; do
    [[ -n "$u" ]] || continue
    adotado "$u" || novos+=("$u")
  done < <(fs_omv_montados)

  if (( ${#novos[@]} > 0 )); then
    carregar
    if [[ -z "${UUID_NUVEM:-}" ]]; then
      # ordena por tamanho: o maior guarda os arquivos (SMB)
      mapfile -t novos < <(for u in "${novos[@]}"; do
        printf '%s %s\n' "$(df -B1 --output=size "/srv/dev-disk-by-uuid-$u" | tail -1 | tr -d ' ')" "$u"
      done | sort -nr | awk '{print $2}')
      if (( ${#novos[@]} >= 2 )); then
        configurar_principal "${novos[0]}" "${novos[1]}"; novos=("${novos[@]:2}")
      else
        configurar_principal "${novos[0]}" "${novos[0]}"; novos=()
      fi
    fi
    for u in "${novos[@]}"; do adicionar_extra "$u"; done
  fi

  # 3) Servicos que dependem do disco principal
  carregar
  if [[ -n "${UUID_NUVEM:-}" ]] && mountpoint -q "/srv/dev-disk-by-uuid-$UUID_NUVEM"; then
    etapa nextcloud  nextcloud  "Nextcloud"
    etapa manutencao manutencao "Cron, watchdog e backup"
    if feita nextcloud && [[ -f "$SENHA_ARQ" ]]; then rm -f "$SENHA_ARQ"; fi
    dominios_tailscale
  fi
  escrever_discos_json
}

modo_organizar() {
  [[ -f "$ESTADO_DIR/base-ok" ]] || exit 0
  mkdir -p "$RUN_DIR"
  exec 9>"$LOCK"; flock -n 9 || exit 0
  # So registra no log quando algo acontece. (Nao usar "|| rc=$?" aqui:
  # no bash isso desligaria o set -e dentro de toda a funcao.)
  local tmp rc; tmp=$(mktemp "$RUN_DIR/.org.XXXX")
  set +e
  ( set -e; organizar_interno ) > "$tmp" 2>&1
  rc=$?
  set -e
  if [[ -s "$tmp" ]]; then
    { echo "----- $(date -Is) organizador -----"; cat "$tmp"; } >> "$LOG"
    cat "$tmp"
  fi
  rm -f "$tmp"
  return "$rc"
}

modo_formatar() {   # apaga um disco com dados, a pedido do usuario
  local d=${1:-}
  [[ -f "$ESTADO_DIR/base-ok" ]] || morrer "A instalacao base ainda nao terminou."
  [[ -b "$d" ]] || morrer "Disco $d nao existe."
  listar_discos | cut -f1 | grep -qx "$d" || morrer "$d nao e um disco valido (o microSD do sistema nao pode ser apagado)."
  disco_montado "$d" && morrer "$d esta em uso. Desconecte e reconecte o disco, ou desmonte-o pelo painel do OMV."
  exec 9>"$LOCK"; flock 9
  titulo "Apagando e preparando $d"
  local u; u=$(formatar_disco "$d" "NAS_$(date +%H%M%S)")
  registrar_fs "$u"
  organizar_interno
}

# -----------------------------------------------------------------------------
# Verificacao
# -----------------------------------------------------------------------------
nextcloud_so_no_ssd() {
  local c src n=0
  for c in nextcloud nextcloud_db; do
    while read -r src; do
      [[ -n "$src" ]] || continue
      [[ "$src" == /srv/dev-disk-by-uuid-* ]] || return 1
      mountpoint -q "/srv/$(cut -d/ -f3 <<< "$src")" || return 1
      n=$((n+1))
    done < <(docker inspect "$c" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}')
  done
  (( n > 0 ))
}

verificar() {
  carregar
  titulo "Verificacao"
  local falhas=0
  chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else erro "$1"; falhas=$((falhas+1)); fi; }
  chk "Painel do OpenMediaVault (porta 80)"   "curl -fsS -o /dev/null http://127.0.0.1/"
  chk "Compartilhamento SMB (smbd)"           "systemctl is-active smbd"
  chk "Docker ativo"                          "systemctl is-active docker"
  chk "Organizador de SSDs (timer)"           "systemctl is-active nas-organizador.timer"
  if [[ "${NAS_TAILSCALE:-s}" == s ]]; then
    chk "Tailscale instalado"                 "systemctl is-active tailscaled"
    if ts_ip >/dev/null; then
      chk "Tailscale conectado"               "ts_ip"
    else
      aviso "Tailscale ainda nao conectado (faca o login pela pagina do NAS)."
    fi
  fi
  if [[ -z "${UUID_NUVEM:-}" ]]; then
    aviso "Nenhum SSD em uso ainda: conecte um SSD e aguarde ~1 minuto."
  else
    local u
    for u in $(printf '%s\n' "$UUID_DADOS" "$UUID_NUVEM" ${EXTRAS:-} | sort -u); do
      chk "SSD montado: /srv/dev-disk-by-uuid-$u" "mountpoint -q /srv/dev-disk-by-uuid-$u"
    done
    chk "Nextcloud instalado e respondendo"   "curl -fsS http://127.0.0.1:$NC_PORTA/status.php | jq -e '.installed==true'"
    chk "Docker exige o SSD montado"          "systemctl show docker -p RequiresMountsFor | grep -q dev-disk-by-uuid"
    chk "Nada do Nextcloud gravado no microSD" "nextcloud_so_no_ssd"
    chk "Timer do cron do Nextcloud"          "systemctl is-active nextcloud-cron.timer"
    chk "Timer do watchdog"                   "systemctl is-active nextcloud-watchdog.timer"
    chk "Timer do backup"                     "systemctl is-active nas-config-backup.timer"
  fi
  echo
  if (( falhas == 0 )); then ok "Tudo certo."; else aviso "$falhas verificacao(oes) falharam."; fi
  return "$falhas"
}

resumo_final() {
  carregar
  local ip ts hn; ip=$(ip_lan); ts=$(ts_ip || true); hn=$(hostname)
  {
    echo "NAS - instalado em $(date '+%d/%m/%Y %H:%M') por instalar-nas.sh v$VERSAO"
    echo
    echo "Usuario: $NAS_USUARIO   (a senha e a que voce escolheu)"
    echo
    echo "Pagina do NAS ....: http://$hn.local:8000   ou   http://$ip:8000"
    echo "Painel do OMV ....: http://$ip        (usuario: admin, mesma senha)"
    echo "Nextcloud ........: http://$ip:$NC_PORTA"
    echo "Arquivos (Windows): \\\\$ip\\dados"
    echo "Arquivos (Mac/Lin): smb://$ip/dados"
    if [[ -n "$ts" ]]; then
      echo
      echo "Fora de casa (com o app Tailscale ligado):"
      echo "  Nextcloud ......: http://$ts:$NC_PORTA"
      echo "  Arquivos .......: \\\\$ts\\dados"
    fi
    echo
    echo "Dica: reserve o IP $ip para o NAS no seu roteador (DHCP fixo)."
  } | tee "$CRED"
  chmod 600 "$CRED"
}

# -----------------------------------------------------------------------------
# Modo terminal (interativo)
# -----------------------------------------------------------------------------
modo_terminal() {
  echo
  echo "${C_AZ}  Instalador do NAS domestico v$VERSAO${C_0}"
  echo "  OpenMediaVault + SMB + Nextcloud + Tailscale"
  carregar
  if [[ -z "${NAS_USUARIO:-}" ]]; then
    titulo "Configuracao"
    local p
    while true; do
      perguntar NAS_USUARIO "Nome do usuario" "${SUDO_USER:-nas}"
      p=$(usuario_valido "$NAS_USUARIO"); [[ -z "$p" ]] && break
      aviso "$p"; NAS_USUARIO=""
    done
    local senha; ler_senha senha "Senha (minimo 8 caracteres)"
    ( umask 077; printf '%s' "$senha" > "$SENHA_ARQ" )
    if sim_ou_nao "Instalar o Tailscale para acessar o NAS fora de casa?" s; then NAS_TAILSCALE=s; else NAS_TAILSCALE=n; fi
    salvar NAS_USUARIO "$NAS_USUARIO"; salvar NAS_TAILSCALE "$NAS_TAILSCALE"
  elif [[ ! -f "$ESTADO_DIR/base-ok" && ! -f "$SENHA_ARQ" ]]; then
    local senha; info "Para continuar, informe de novo a senha de $NAS_USUARIO."
    ler_senha senha "Senha"; ( umask 077; printf '%s' "$senha" > "$SENHA_ARQ" )
  fi

  modo_base

  if [[ "${NAS_TAILSCALE:-s}" == s ]] && ! ts_ip >/dev/null; then
    titulo "Login no Tailscale"
    info "Vai aparecer um LINK. Abra no celular ou no PC e entre na sua conta"
    info "Tailscale (pode criar uma gratis com Google/Microsoft)."
    tailscale up --netfilter-mode=off --hostname "$(hostname)" || aviso "Login no Tailscale nao concluido; faca depois pela pagina do NAS."
  fi

  titulo "SSDs"
  if [[ -z "$(listar_discos)" ]]; then
    info "Nenhum SSD conectado. Quando conectar, ele sera preparado sozinho em ~1 minuto."
  else
    set +e; ESTAVEL_SEG=0 modo_organizar; set -e
    if jq -e 'any(.[]; .estado=="com_dados")' "$DISCOS_JSON" >/dev/null 2>&1; then
      aviso "Ha disco(s) com dados que NAO foram apagados:"
      jq -r '.[] | select(.estado=="com_dados") | "      \(.dev)  \(.tamanho)  \(.modelo)"' "$DISCOS_JSON"
      info "Para usar um deles (APAGA TUDO):  sudo instalar-nas.sh --formatar /dev/sdX"
      info "ou formate pelo painel do OMV (Armazenamento > Discos)."
    fi
  fi
  verificar || true
  titulo "Pronto!"
  resumo_final
}

# -----------------------------------------------------------------------------
main() {
  case "${1:-}" in
    --verificar)
      [[ $EUID -eq 0 ]] || { echo "Rode com sudo."; exit 1; }
      trap - ERR; local rc=0; verificar || rc=$?; exit "$rc" ;;
    --organizar)
      [[ $EUID -eq 0 ]] || exit 1
      modo_organizar ;;
    --formatar)
      [[ $EUID -eq 0 ]] || exit 1
      iniciar_log "$@"; modo_formatar "${2:-}" ;;
    --base)
      [[ $EUID -eq 0 ]] || exit 1
      iniciar_log "$@"; prog_set fase instalando; modo_base ;;
    "")
      [[ $EUID -eq 0 ]] || { echo "Rode com sudo:  sudo bash $0"; exit 1; }
      iniciar_log; verificar_sistema; modo_terminal ;;
    *)
      echo "Uso: $0 [--base | --organizar | --formatar /dev/sdX | --verificar]"; exit 1 ;;
  esac
}

main "$@"
