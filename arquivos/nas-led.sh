#!/bin/bash
# =============================================================================
#  nas-led - mostra o estado do NAS no LED de status da placa (o LED que pisca
#  sozinho quando o Linux esta ligado; na ROCK 4B+ e o "led-0 / status").
#
#    nas-led ligando        tum-tum (batimento)   Linux ligando / pagina fora do ar
#    nas-led preparando     pisca rapido          1o boot: baixando o necessario
#    nas-led sem-internet   pisca devagar         sem internet: confira o cabo
#    nas-led pronto         aceso fixo            pode abrir http://nas.local:8000
#
#  Em placas sem LED controlavel, nao faz nada (e nunca falha).
# =============================================================================
set -u

base=${NAS_LEDS:-/sys/class/leds}           # NAS_LEDS: so para testes
led=""
for d in "$base"/*:status "$base"/*status* "$base"/*user*; do
  if [[ -e "$d/trigger" ]]; then led=$d; break; fi
done
[[ -n "$led" ]] || exit 0

gatilho() { echo "$1" > "$led/trigger" 2>/dev/null; }

piscar() {   # $1 = ms aceso, $2 = ms apagado
  grep -qw timer "$led/trigger" 2>/dev/null || modprobe ledtrig-timer 2>/dev/null
  if gatilho timer; then
    echo "$1" > "$led/delay_on"  2>/dev/null
    echo "$2" > "$led/delay_off" 2>/dev/null
  else
    gatilho heartbeat
  fi
}

case "${1:-}" in
  ligando)      gatilho heartbeat ;;
  preparando)   piscar 100 100 ;;
  sem-internet) piscar 1500 1500 ;;
  pronto)
    if ! gatilho default-on; then
      gatilho none
      cat "$led/max_brightness" > "$led/brightness" 2>/dev/null
    fi ;;
  *) echo "uso: nas-led ligando|preparando|sem-internet|pronto" >&2; exit 2 ;;
esac
exit 0
