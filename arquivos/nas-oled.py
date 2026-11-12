#!/usr/bin/env python3
# =============================================================================
#  nas-oled.py - mostra o estado do NAS numa telinha OLED 0,96" 128x64 (SSD1306,
#  I2C, ex.: GM009605) ligada nos pinos 1, 3, 5 e 6 da ROCK 4B+ (barramento I2C 7).
#
#  So usa a biblioteca padrao do Python. Sem tela ligada, encerra sem erro.
#
#    nas-oled.py                    roda na placa (servico nas-oled)
#    nas-oled.py --previa PASTA     gera imagens PNG das telas (para testar no PC)
#    nas-oled.py --quadro-ligando ARQ   grava a tela "LIGANDO" crua (1024 bytes),
#                                   que o U-Boot do NAS mostra logo no inicio do boot
# =============================================================================
import glob
import json
import os
import socket
import struct
import subprocess
import sys
import time
import unicodedata
import zlib

LARG, ALT = 128, 64
ENDERECOS = (0x3C, 0x3D)
I2C_SLAVE = 0x0703
PROGRESSO = "/var/lib/nas-instalador/progresso.json"
PREPARADO = "/var/lib/nas-instalador/preparado"
CONF = "/etc/nas-instalador.conf"
BASE_OK = "/var/lib/nas-instalador/base-ok"
DISCOS = "/run/nas/discos.json"
LOG_PREPARAR = "/var/log/nas-preparar.log"
PORTA = 8000
ESPERA_IP = 180          # segundos depois do boot antes de dizer "SEM REDE"
ESPERA_TELA = 30         # segundos procurando a tela (o I2C pode demorar a aparecer)
ETAPAS = ["base", "omv", "usuario", "docker", "tailscale"]
NOMES = {"base": "Sistema", "omv": "OpenMediaVault", "usuario": "Usuario/SMB",
         "docker": "Docker", "tailscale": "Tailscale"}

# Fonte 5x7 (ASCII 32-126): 5 colunas por caractere, bit 0 = linha de cima.
FONTE = bytes.fromhex(
    "0000000000" "00005f0000" "0007000700" "147f147f14" "242a7f2a12" "2313086462"
    "3649552250" "0005030000" "001c224100" "0041221c00" "082a1c2a08" "08083e0808"
    "0050300000" "0808080808" "0060600000" "2010080402" "3e5149453e" "00427f4000"
    "4261514946" "2141454b31" "1814127f10" "2745454539" "3c4a494930" "0171090503"
    "3649494936" "064949291e" "0036360000" "0056360000" "0008142241" "1414141414"
    "4122140800" "0201510906" "324979413e" "7e1111117e" "7f49494936" "3e41414122"
    "7f4141221c" "7f49494941" "7f09090101" "3e41415132" "7f0808087f" "00417f4100"
    "2040413f01" "7f08142241" "7f40404040" "7f0204027f" "7f0408107f" "3e4141413e"
    "7f09090906" "3e4151215e" "7f09192946" "4649494931" "01017f0101" "3f4040403f"
    "1f2040201f" "7f2018207f" "6314081463" "0304780403" "6151494543" "00007f4141"
    "0204081020" "41417f0000" "0402010204" "4040404040" "0001020400" "2054545478"
    "7f48444438" "3844444420" "384444487f" "3854545418" "087e090102" "081454543c"
    "7f08040478" "00447d4000" "2040443d00" "007f102844" "00417f4000" "7c04180478"
    "7c08040478" "3844444438" "7c14141408" "081414187c" "7c08040408" "4854545420"
    "043f444020" "3c4040207c" "1c2040201c" "3c4030403c" "4428102844" "0c5050503c"
    "4464544c44" "0008364100" "00007f0000" "0041360800" "1008081008"
)


def sem_acento(texto):
    return unicodedata.normalize("NFKD", str(texto)).encode("ascii", "ignore").decode()


class Quadro:
    """Imagem de 128x64 em memoria, no formato do SSD1306 (8 paginas de 8 linhas)."""

    def __init__(self):
        self.buf = bytearray(LARG * ALT // 8)

    def ponto(self, x, y):
        if 0 <= x < LARG and 0 <= y < ALT:
            self.buf[(y // 8) * LARG + x] |= 1 << (y % 8)

    def texto(self, x, y, txt, escala=1):
        for ch in sem_acento(txt):
            c = ord(ch)
            if c < 32 or c > 126:
                c = 63   # "?"
            col = FONTE[(c - 32) * 5:(c - 32) * 5 + 5]
            for i, bits in enumerate(col):
                for j in range(7):
                    if bits >> j & 1:
                        for dx in range(escala):
                            for dy in range(escala):
                                self.ponto(x + i * escala + dx, y + j * escala + dy)
            x += 6 * escala

    def linha_h(self, y):
        for x in range(LARG):
            self.ponto(x, y)

    def png(self, caminho, zoom=4):
        """Salva como PNG (pixels acesos em azul-claro), so com a biblioteca padrao."""
        linhas = bytearray()
        for y in range(ALT * zoom):
            linhas.append(0)
            for x in range(LARG * zoom):
                aceso = self.buf[(y // zoom // 8) * LARG + x // zoom] >> (y // zoom % 8) & 1
                linhas += bytes((90, 200, 255) if aceso else (8, 10, 18))

        def bloco(tipo, dados):
            return (struct.pack(">I", len(dados)) + tipo + dados +
                    struct.pack(">I", zlib.crc32(tipo + dados) & 0xFFFFFFFF))
        cab = struct.pack(">IIBBBBB", LARG * zoom, ALT * zoom, 8, 2, 0, 0, 0)
        with open(caminho, "wb") as f:
            f.write(b"\x89PNG\r\n\x1a\n" + bloco(b"IHDR", cab) +
                    bloco(b"IDAT", zlib.compress(bytes(linhas), 9)) + bloco(b"IEND", b""))


def desenhar(titulo, linhas):
    """Tela padrao: titulo grande (2x), linha separadora e ate 5 linhas de 21 letras."""
    q = Quadro()
    q.texto(0, 0, sem_acento(titulo)[:10], escala=2)
    q.linha_h(17)
    for i, txt in enumerate(linhas[:5]):
        q.texto(0, 20 + i * 9, sem_acento(txt)[:21])
    return q


# ------------------------------------------------------------------ tela (I2C)
class Tela:
    INICIO = [0xAE, 0xD5, 0x80, 0xA8, 0x3F, 0xD3, 0x00, 0x40, 0x8D, 0x14, 0x20, 0x00,
              0xA1, 0xC8, 0xDA, 0x12, 0x81, 0x8F, 0xD9, 0xF1, 0xDB, 0x40, 0xA4, 0xA6, 0xAF]

    def __init__(self, fd):
        self.fd = fd

    @staticmethod
    def procurar():
        import fcntl
        # So o I2C 7 (pinos 3 e 5): os outros barramentos da placa tem chips do
        # sistema (energia, USB-C, HDMI) e nao devem receber comandos de tela.
        barramentos = [b for b in (os.environ.get("NAS_OLED_I2C", "/dev/i2c-7"),) if glob.glob(b)]
        for caminho in barramentos:
            for end in ENDERECOS:
                try:
                    fd = os.open(caminho, os.O_RDWR)
                except OSError:
                    break
                try:
                    fcntl.ioctl(fd, I2C_SLAVE, end)
                    os.write(fd, bytes([0x00, 0xAE]))   # responde? (desliga a tela)
                    return Tela(fd), f"{caminho} 0x{end:02x}"
                except OSError:
                    os.close(fd)
        return None, ""

    def comandos(self, *cmds):
        os.write(self.fd, bytes([0x00, *cmds]))

    def iniciar(self):
        for c in self.INICIO:
            self.comandos(c)

    def mostrar(self, quadro):
        self.comandos(0x21, 0, LARG - 1)
        self.comandos(0x22, 0, ALT // 8 - 1)
        for i in range(0, len(quadro.buf), 32):
            os.write(self.fd, bytes([0x40]) + bytes(quadro.buf[i:i + 32]))

    def brilho(self, valor):
        self.comandos(0x81, valor)


# --------------------------------------------------------------- estado do NAS
def ler_json(caminho, padrao):
    try:
        with open(caminho, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return padrao


def ip_local():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("1.1.1.1", 80))
        return s.getsockname()[0]
    except OSError:
        return ""
    finally:
        s.close()


def tempo_ligado():
    try:
        with open("/proc/uptime") as f:
            return float(f.read().split()[0])
    except (OSError, ValueError, IndexError):
        return 0.0


def porta_aberta(porta):
    try:
        with socket.create_connection(("127.0.0.1", porta), timeout=1):
            return True
    except OSError:
        return False


def servico_ativo(nome):
    try:
        r = subprocess.run(["systemctl", "is-active", nome], capture_output=True, text=True, timeout=5)
        return r.stdout.strip() in ("active", "activating")
    except (OSError, subprocess.TimeoutExpired):
        return False


def esperando_internet():
    try:
        with open(LOG_PREPARAR, encoding="utf-8", errors="replace") as f:
            fim = f.readlines()[-3:]
    except OSError:
        return False
    return any("aguardando internet" in l or "SEM INTERNET" in l for l in fim)


def estado():
    return {
        "ip": ip_local(),
        "ligado_ha": tempo_ligado(),
        "preparado": os.path.exists(PREPARADO),
        "preparando": servico_ativo("nas-preparar.service"),
        "sem_internet": esperando_internet(),
        "pagina": porta_aberta(PORTA),
        "configurado": os.path.exists(CONF),
        "base_ok": os.path.exists(BASE_OK),
        "prog": ler_json(PROGRESSO, {}),
        "discos": ler_json(DISCOS, []),
        "host": socket.gethostname(),
    }


def tela_para(e):
    """Decide o que mostrar. Devolve (titulo, linhas)."""
    endereco = f"{e['host']}.local:{PORTA}"
    ip = e["ip"] or "sem IP"
    if not e["ip"]:
        # No boot a rede leva um tempo para subir: so reclama depois de ESPERA_IP.
        if e.get("ligado_ha", 0) < ESPERA_IP:
            return "LIGANDO", ["Aguarde...", "", "", "", ""]
        return "SEM REDE", ["Ja faz 3 minutos e", "a placa nao entrou", "na rede. Confira o", "cabo e o roteador."]
    if not e["preparado"]:
        if e["sem_internet"] and e.get("ligado_ha", 0) >= ESPERA_IP:
            return "SEM NET", ["A placa nao acessa", "a internet.", "Confira o cabo e o", "roteador.", f"IP {ip}"]
        return "PREPARANDO", ["Primeiro boot:", "aguarde ~10 minutos", "e nao desligue.", "", f"IP {ip}"]
    if not e["pagina"]:
        return "LIGANDO", ["Abrindo a pagina...", "", "", "", f"IP {ip}"]
    if not e["configurado"]:
        return "PRONTO!", ["Abra no navegador:", endereco, f"ou {ip}:{PORTA}", "e crie seu usuario."]
    prog = e["prog"]
    etapas = prog.get("etapas", {})
    if not e["base_ok"]:
        if prog.get("erro"):
            return "ERRO", ["Na instalacao.", "Abra a pagina e use", "Tentar de novo:", endereco]
        feitas = sum(1 for k in ETAPAS if etapas.get(k) == "ok")
        atual = next((k for k in ETAPAS if etapas.get(k) == "andamento"), "")
        barra = "#" * (feitas * 4) + "-" * ((len(ETAPAS) - feitas) * 4)
        return "INSTALANDO", [f"Etapa {min(feitas + 1, 5)} de 5", NOMES.get(atual, "..."),
                              f"[{barra[:19]}]", "Leva 20 a 40 min", f"IP {ip}"]
    linhas = [endereco, f"IP {ip}"]
    discos = e["discos"]
    if not discos:
        linhas += ["Sem disco: ligue um", "SSD/HD na USB azul"]
    for d in discos[:2]:
        rotulo = {"em_uso": "em uso", "vazio": "novo", "preparando": "preparando",
                  "com_dados": "TEM DADOS", "em_uso_outro": "fora do NAS"}.get(d.get("estado"), d.get("estado", ""))
        linhas.append(f"{d.get('tamanho', '')} {rotulo}")
    nc = {"instalando": "Nextcloud: instalando", "pronto": "Nextcloud: pronto"}.get(prog.get("nextcloud"))
    if nc and len(linhas) < 5:
        linhas.append(nc)
    if etapas.get("nextcloud") == "erro" and len(linhas) < 5:
        linhas.append("Nextcloud: erro")
    return "NAS OK", linhas


def quadro_ligando():
    """Tela "LIGANDO". O U-Boot do NAS mostra exatamente esta imagem logo no inicio
    do boot (arquivo /boot/nas-oled-ligando.bin, gerado por --quadro-ligando)."""
    return desenhar("LIGANDO", ["Aguarde...", "", "", "", ""])


# -------------------------------------------------------------------- execucao
def rodar():
    # O servico sobe cedo no boot; o /dev/i2c-7 pode levar alguns segundos.
    limite = time.time() + ESPERA_TELA
    tela, onde = Tela.procurar()
    while tela is None and time.time() < limite:
        time.sleep(2)
        tela, onde = Tela.procurar()
    if tela is None:
        print("nas-oled: nenhuma tela OLED encontrada no I2C; nada a fazer.")
        return 0
    print(f"nas-oled: tela encontrada em {onde}")
    tela.iniciar()
    tela.mostrar(quadro_ligando())
    anterior, desde = None, time.time()
    while True:
        try:
            atual = tela_para(estado())
            if atual != anterior:
                tela.mostrar(desenhar(*atual))
                tela.brilho(0x8F)
                anterior, desde = atual, time.time()
            elif time.time() - desde > 600:
                tela.brilho(0x08)       # parado ha 10 min: brilho baixo (poupa o OLED)
        except OSError as erro:         # tela desconectada ou ruido no I2C
            print(f"nas-oled: {erro}; tentando de novo")
            time.sleep(10)
            try:
                tela.iniciar()
                anterior = None
            except OSError:
                pass
        time.sleep(3)


def previa(pasta):
    """Gera um PNG para cada situacao (sem placa), para conferir o desenho no PC."""
    os.makedirs(pasta, exist_ok=True)
    base = {"ip": "192.168.0.39", "preparado": True, "preparando": False, "sem_internet": False,
            "pagina": True, "configurado": True, "base_ok": True, "host": "nas",
            "prog": {"etapas": {k: "ok" for k in ETAPAS}, "nextcloud": "pronto"},
            "discos": [{"tamanho": "81GB", "estado": "em_uso"}]}
    casos = {
        "0-ligando": {"ip": "", "ligado_ha": 20},
        "1-sem-rede": {"ip": "", "ligado_ha": 300},
        "2-preparando": {"preparado": False, "preparando": True},
        "3-sem-internet": {"preparado": False, "sem_internet": True, "ligado_ha": 300},
        "4-pronto": {"configurado": False, "base_ok": False},
        "5-instalando": {"base_ok": False, "prog": {"etapas": {"base": "ok", "omv": "andamento"}}},
        "6-erro": {"base_ok": False, "prog": {"etapas": {"base": "ok", "omv": "erro"}, "erro": "x"}},
        "7-nas-ok": {},
        "8-sem-disco": {"discos": [], "prog": {"etapas": {}, "nextcloud": "aguardando_disco"}},
    }
    for nome, mudar in casos.items():
        desenhar(*tela_para({**base, **mudar})).png(os.path.join(pasta, nome + ".png"))
        print(nome, tela_para({**base, **mudar}))
    return 0


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--previa":
        sys.exit(previa(sys.argv[2]))
    if len(sys.argv) == 3 and sys.argv[1] == "--quadro-ligando":
        # 1024 bytes no formato da memoria do SSD1306 (8 paginas x 128 colunas)
        with open(sys.argv[2], "wb") as f:
            f.write(bytes(quadro_ligando().buf))
        sys.exit(0)
    sys.exit(rodar())
