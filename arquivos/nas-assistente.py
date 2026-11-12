#!/usr/bin/env python3
"""Pagina do NAS: configuracao inicial e painel, aberta no navegador do PC/celular.

Roda na placa (sem monitor). Porta 8000 sempre; porta 80 so ate a configuracao
(depois a porta 80 passa a ser do painel do OpenMediaVault).
Usa apenas a biblioteca padrao do Python.
"""
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONF = "/etc/nas-instalador.conf"
SENHA_ARQ = "/etc/nas-instalador.senha"
AUTH = "/etc/nas-assistente/auth.json"
PROGRESSO = "/var/lib/nas-instalador/progresso.json"
BASE_OK = "/var/lib/nas-instalador/base-ok"
DISCOS = "/run/nas/discos.json"
LOG = "/var/log/nas-instalador.log"
INSTALADOR = "/usr/local/sbin/instalar-nas.sh"
PORTA = 8000
NC_PORTA = 8081

ts_login = {"url": "", "qr": "", "rodando": False, "erro": ""}
servidor80 = None


# --------------------------------------------------------------------------- util
def ler_json(caminho, padrao):
    try:
        with open(caminho, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return padrao


def rodar(*cmd, timeout=20):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return 1, ""


def configurado():
    return os.path.exists(CONF)


def ip_local():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("1.1.1.1", 80))
        return s.getsockname()[0]
    except OSError:
        return ""
    finally:
        s.close()


def usuario_conf():
    try:
        with open(CONF, encoding="utf-8") as f:
            for linha in f:
                if linha.startswith("NAS_USUARIO="):
                    return linha.split("=", 1)[1].strip().strip("'\"")
    except OSError:
        pass
    return ""


def validar(usuario, senha):
    if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,30}", usuario or ""):
        return "Nome de usuario: use so letras minusculas, numeros, - ou _ (sem espacos)."
    if usuario in ("admin", "root", "www-data", "nas-admin"):
        return "Esse nome e reservado; escolha outro."
    if len(senha or "") < 8:
        return "A senha precisa ter pelo menos 8 caracteres."
    if any(c in senha for c in "'\"\\:\n"):
        return "Nao use aspas, barra invertida nem dois-pontos na senha."
    return ""


# ---------------------------------------------------------------- autenticacao
def hash_senha(senha, sal=None):
    sal = sal or secrets.token_hex(16)
    h = hashlib.pbkdf2_hmac("sha256", senha.encode(), bytes.fromhex(sal), 200_000).hex()
    return sal, h


def autenticado(handler):
    """Antes da configuracao a pagina e aberta; depois exige usuario e senha."""
    dados = ler_json(AUTH, None)
    if not dados:
        return True
    cab = handler.headers.get("Authorization", "")
    if not cab.startswith("Basic "):
        return False
    try:
        usuario, senha = base64.b64decode(cab[6:]).decode().split(":", 1)
    except (ValueError, UnicodeDecodeError):
        return False
    _, h = hash_senha(senha, dados["sal"])
    return usuario == dados["usuario"] and hmac.compare_digest(h, dados["hash"])


# ------------------------------------------------------------------- tailscale
def tailscale_estado():
    instalado = os.path.exists("/usr/bin/tailscale") or os.path.exists("/usr/sbin/tailscale")
    rc, ip = rodar("tailscale", "ip", "-4") if instalado else (1, "")
    ip = ip.splitlines()[0] if rc == 0 and ip else ""
    return {
        "instalado": instalado,
        "conectado": bool(ip),
        "ip": ip,
        "url": "" if ip else ts_login["url"],
        "qr": "" if ip else ts_login["qr"],
        "rodando": ts_login["rodando"],
        "erro": ts_login["erro"],
    }


def tailscale_login():
    if ts_login["rodando"]:
        return
    ts_login.update(url="", qr="", erro="", rodando=True)

    def trabalho():
        try:
            p = subprocess.Popen(
                ["tailscale", "up", "--netfilter-mode=off", "--hostname", socket.gethostname()],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            for linha in p.stdout:
                m = re.search(r"https://login\.tailscale\.com/\S+", linha)
                if m and not ts_login["url"]:
                    url = m.group(0)
                    _, svg = rodar("qrencode", "-t", "SVG", "-m", "1", "-o", "-", url)
                    ts_login.update(url=url, qr=svg)
            if p.wait() != 0 and not tailscale_estado()["conectado"]:
                ts_login["erro"] = "O login nao foi concluido. Tente de novo."
        except OSError as e:
            ts_login["erro"] = f"Falha ao iniciar o Tailscale: {e}"
        finally:
            ts_login["rodando"] = False

    threading.Thread(target=trabalho, daemon=True).start()


# ---------------------------------------------------------------------- discos
# Mensagens do kernel que aparecem quando algo foi ligado na USB e nao respondeu
# direito (tipico de HD sem energia suficiente, cabo ruim ou porta fraca).
PROBLEMAS_USB = ("over-current", "device descriptor read", "unable to enumerate",
                 "not accepting address", "uas_eh_abort_handler")
_discos = {"t": 0.0, "usb": False}
_discos_trava = threading.Lock()


def discos_atuais(base_ok):
    """Antes da instalacao base terminar, o organizador ainda nao roda. Entao a
    propria pagina pede a lista (so leitura) a cada 10 s, para o usuario ver o
    disco assim que o conecta. Tambem procura sinais de problema na USB."""
    with _discos_trava:
        if time.time() - _discos["t"] >= 10:
            _discos["t"] = time.time()
            if not base_ok:
                rodar(INSTALADOR, "--listar", timeout=30)
            rc, saida = rodar("journalctl", "-k", "-S", "-3min", "-o", "cat",
                              "--no-pager", timeout=10)
            _discos["usb"] = rc == 0 and any(p in saida for p in PROBLEMAS_USB)
    return ler_json(DISCOS, []), _discos["usb"]


# ---------------------------------------------------------------------- estado
def estado(completo):
    prog = ler_json(PROGRESSO, {"etapas": {}})
    ip = ip_local()
    host = socket.gethostname()
    _, base_ativo = rodar("systemctl", "is-active", "nas-base.service")
    base_ok = os.path.exists(BASE_OK)
    discos, usb_problema = discos_atuais(base_ok)
    e = {
        "configurado": configurado(),
        "usuario": usuario_conf(),
        "base_ok": base_ok,
        "base_ativo": base_ativo in ("active", "activating"),
        "etapas": prog.get("etapas", {}),
        "erro": prog.get("erro", ""),
        "nextcloud": prog.get("nextcloud", "aguardando_disco"),
        "etapa_nextcloud": prog.get("etapas", {}).get("nextcloud", ""),
        "tailscale": tailscale_estado(),
        "discos": discos,
        "usb_problema": usb_problema,
        "enderecos": {
            "ip": ip, "host": host,
            "pagina": f"http://{host}.local:{PORTA}",
            "omv": f"http://{ip}",
            "nextcloud": f"http://{ip}:{NC_PORTA}",
            "smb_win": f"\\\\{ip}\\dados",
            "smb_mac": f"smb://{ip}/dados",
        },
        "log": [],
    }
    if completo:
        try:
            with open(LOG, encoding="utf-8", errors="replace") as f:
                e["log"] = f.readlines()[-30:]
        except OSError:
            pass
    return e


# ---------------------------------------------------------------------- acoes
def configurar(dados):
    if configurado():
        return 409, {"erro": "O NAS ja foi configurado."}
    usuario = (dados.get("usuario") or "").strip().lower()
    senha = dados.get("senha") or ""
    problema = validar(usuario, senha)
    if problema:
        return 400, {"erro": problema}
    os.makedirs(os.path.dirname(AUTH), exist_ok=True)
    velho = os.umask(0o077)
    try:
        with open(SENHA_ARQ, "w", encoding="utf-8") as f:
            f.write(senha)
        sal, h = hash_senha(senha)
        with open(AUTH, "w", encoding="utf-8") as f:
            json.dump({"usuario": usuario, "sal": sal, "hash": h}, f)
        with open(CONF, "w", encoding="utf-8") as f:
            f.write(f"NAS_USUARIO={usuario}\nNAS_TAILSCALE=s\n")
    finally:
        os.umask(velho)
    # libera a porta 80 para o painel do OpenMediaVault
    if servidor80 is not None:
        def liberar_80(srv=servidor80):
            srv.shutdown()
            srv.server_close()
        threading.Thread(target=liberar_80, daemon=True).start()
    rodar("systemctl", "start", "--no-block", "nas-base.service")
    return 200, {"ok": True}


def tentar_de_novo():
    rodar("systemctl", "reset-failed", "nas-base.service")
    rodar("systemctl", "start", "--no-block", "nas-base.service")
    return 200, {"ok": True}


def formatar(dados):
    dev = dados.get("dev", "")
    if dados.get("confirmacao") != "APAGAR":
        return 400, {"erro": "Digite APAGAR para confirmar."}
    if not os.path.exists(BASE_OK):
        return 409, {"erro": "Espere a instalacao terminar para usar este disco."}
    discos = ler_json(DISCOS, [])
    alvo = next((d for d in discos if d.get("dev") == dev), None)
    if not alvo or alvo.get("estado") != "com_dados":
        return 400, {"erro": "Esse disco nao pode ser apagado por aqui."}
    unidade = f"nas-formatar-{int(time.time())}"
    rc, _ = rodar("systemd-run", f"--unit={unidade}", "--collect", INSTALADOR, "--formatar", dev)
    return (200, {"ok": True}) if rc == 0 else (500, {"erro": "Nao consegui iniciar a formatacao."})


# ---------------------------------------------------------------------- HTTP
class Pagina(BaseHTTPRequestHandler):
    server_version = "NAS"

    def log_message(self, *args):
        pass

    def responder(self, codigo, corpo, tipo="application/json; charset=utf-8"):
        dados = corpo if isinstance(corpo, bytes) else json.dumps(corpo).encode()
        self.send_response(codigo)
        self.send_header("Content-Type", tipo)
        self.send_header("Content-Length", str(len(dados)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(dados)

    def pedir_login(self):
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="NAS - use seu usuario e senha"')
        self.send_header("Content-Length", "0")
        self.end_headers()

    def redirecionar_8000(self):
        host = self.headers.get("Host") or ip_local()
        host = host.rsplit("]", 1)[0] + "]" if host.startswith("[") else host.split(":")[0]
        self.send_response(302)
        self.send_header("Location", f"http://{host}:{PORTA}/")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        if self.server.server_address[1] != PORTA:
            return self.redirecionar_8000()
        if not autenticado(self):
            return self.pedir_login()
        if self.path in ("/", "/index.html"):
            return self.responder(200, HTML.encode(), "text/html; charset=utf-8")
        if self.path == "/api/estado":
            return self.responder(200, estado(completo=True))
        self.responder(404, {"erro": "nao encontrado"})

    def do_POST(self):
        if self.server.server_address[1] != PORTA:
            return self.redirecionar_8000()
        if not autenticado(self):
            return self.pedir_login()
        try:
            tam = min(int(self.headers.get("Content-Length", "0")), 10_000)
            dados = json.loads(self.rfile.read(tam) or b"{}")
        except ValueError:
            return self.responder(400, {"erro": "pedido invalido"})
        if self.path == "/api/configurar":
            return self.responder(*configurar(dados))
        if self.path == "/api/tentar":
            return self.responder(*tentar_de_novo())
        if self.path == "/api/tailscale":
            tailscale_login()
            return self.responder(200, {"ok": True})
        if self.path == "/api/formatar":
            return self.responder(*formatar(dados))
        self.responder(404, {"erro": "nao encontrado"})


HTML = r"""<!doctype html>
<html lang="pt-BR"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>NAS domestico</title>
<style>
:root{--bg:#f4f6f8;--card:#fff;--tx:#1d2733;--sub:#5d6b7a;--bd:#dde3ea;--az:#1f6feb;--vd:#1a7f37;--am:#9a6700;--vm:#cf222e}
@media (prefers-color-scheme:dark){:root{--bg:#0f1419;--card:#18202a;--tx:#e6edf3;--sub:#9aa7b4;--bd:#2b3642;--az:#4c8dff;--vd:#3fb950;--am:#d29922;--vm:#f85149}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--tx);font:16px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:720px;margin:0 auto;padding:16px}
h1{font-size:1.5rem;margin:8px 0 4px}h2{font-size:1.1rem;margin:0 0 10px}
.sub{color:var(--sub);margin:0 0 16px}
.card{background:var(--card);border:1px solid var(--bd);border-radius:12px;padding:16px;margin:0 0 14px}
label{display:block;font-weight:600;margin:10px 0 4px}
input{width:100%;padding:10px;border:1px solid var(--bd);border-radius:8px;background:var(--bg);color:var(--tx);font-size:16px}
button{background:var(--az);color:#fff;border:0;border-radius:8px;padding:10px 16px;font-size:16px;cursor:pointer;margin-top:12px}
button.perigo{background:var(--vm)}button:disabled{opacity:.5;cursor:default}
ul.etapas{list-style:none;padding:0;margin:0}ul.etapas li{padding:6px 0;display:flex;gap:10px;align-items:center}
.ic{width:22px;text-align:center;font-weight:700}.ok{color:var(--vd)}.and{color:var(--az)}.err{color:var(--vm)}.pen{color:var(--sub)}
.msg{padding:10px;border-radius:8px;margin-top:10px}.msg.err{background:color-mix(in srgb,var(--vm) 12%,transparent)}
.msg.info{background:color-mix(in srgb,var(--az) 10%,transparent)}
.disco{border:1px solid var(--bd);border-radius:8px;padding:10px;margin:8px 0}
.tag{display:inline-block;font-size:.8rem;padding:2px 8px;border-radius:99px;border:1px solid currentColor;margin-left:6px}
table{width:100%;border-collapse:collapse}td{padding:6px 4px;border-bottom:1px solid var(--bd);vertical-align:top;word-break:break-all}td:first-child{color:var(--sub);word-break:normal;width:42%}
details pre{white-space:pre-wrap;font-size:.8rem;max-height:260px;overflow:auto;background:var(--bg);padding:8px;border-radius:8px}
.qr svg{width:180px;height:180px;background:#fff;padding:6px;border-radius:8px}
a{color:var(--az)}.oculto{display:none}
</style></head><body><main>
<h1>NAS domestico</h1>
<p class="sub">OpenMediaVault, arquivos na rede, Nextcloud e acesso de fora de casa.</p>
<div id="conexao" class="msg info oculto">Reconectando ao NAS...</div>

<section id="c-config" class="card oculto">
  <h2>1. Crie seu acesso</h2>
  <p>Esse usuario e senha vao servir para os arquivos na rede, o Nextcloud e o painel do NAS.</p>
  <label for="u">Nome de usuario</label><input id="u" autocomplete="username" placeholder="ex.: maria">
  <label for="s1">Senha (minimo 8 caracteres)</label><input id="s1" type="password" autocomplete="new-password">
  <label for="s2">Repita a senha</label><input id="s2" type="password" autocomplete="new-password">
  <button id="b-config">Comecar instalacao</button>
  <div id="m-config" class="msg err oculto"></div>
</section>

<section id="c-inst" class="card oculto">
  <h2>Instalacao</h2>
  <ul class="etapas" id="etapas"></ul>
  <div id="m-inst" class="msg oculto"></div>
  <button id="b-tentar" class="oculto">Tentar de novo</button>
  <details><summary>Detalhes tecnicos</summary><pre id="log"></pre></details>
</section>

<section id="c-ts" class="card oculto">
  <h2>Acesso fora de casa (Tailscale)</h2>
  <div id="ts"></div>
</section>

<section id="c-discos" class="card oculto">
  <h2>Discos (SSD ou HD)</h2>
  <div id="discos"></div>
  <div id="nc" class="msg info"></div>
</section>

<section id="c-end" class="card oculto">
  <h2>Como acessar</h2>
  <table id="end"></table>
</section>
</main>
<script>
const NOMES={base:"Preparando o sistema",omv:"OpenMediaVault (painel do NAS)",usuario:"Usuario e compartilhamento de arquivos",docker:"Docker",tailscale:"Tailscale"};
const ICONES={ok:["&#10003;","ok"],andamento:["&#8987;","and"],erro:["&#10007;","err"]};
const $=id=>document.getElementById(id);
const mostra=(id,sim)=>$(id).classList.toggle("oculto",!sim);
const esc=s=>String(s??"").replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
async function post(url,dados){const r=await fetch(url,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(dados||{})});let j={};try{j=await r.json()}catch(e){}if(!r.ok)throw new Error(j.erro||"Erro "+r.status);return j}

$("b-config").onclick=async()=>{
  const u=$("u").value.trim().toLowerCase(),a=$("s1").value,b=$("s2").value;
  const m=$("m-config");m.classList.add("oculto");
  if(a!==b){m.textContent="As senhas nao conferem.";m.classList.remove("oculto");return}
  $("b-config").disabled=true;
  try{await post("/api/configurar",{usuario:u,senha:a});
      alert("Pronto! A instalacao comecou. Quando o navegador pedir login, use o usuario e a senha que voce acabou de criar.");
      location.reload()}
  catch(e){m.textContent=e.message;m.classList.remove("oculto");$("b-config").disabled=false}
};
$("b-tentar").onclick=()=>post("/api/tentar").then(atualizar);

function etapas(e){
  const ids=["base","omv","usuario","docker","tailscale"];
  $("etapas").innerHTML=ids.map(id=>{const st=e.etapas[id]||"";const [ic,cl]=ICONES[st]||["&#8226;","pen"];
    return `<li><span class="ic ${cl}">${ic}</span>${NOMES[id]}${st==="andamento"?" <small>(em andamento)</small>":""}</li>`}).join("");
  const m=$("m-inst");
  if(e.erro){m.className="msg err";m.textContent="Problema: "+e.erro;mostra("b-tentar",!e.base_ativo)}
  else if(e.base_ok){m.className="msg info";m.textContent="Instalacao concluida."}
  else{m.className="msg info";m.textContent="Instalando... isso leva de 20 a 40 minutos. Pode deixar esta pagina aberta ou voltar depois."}
  mostra("m-inst",true);if(!e.erro)mostra("b-tentar",false);
  $("log").textContent=(e.log||[]).join("");
}
function tailscale(e){
  const t=e.tailscale,d=$("ts");
  if(t.conectado){d.innerHTML=`<p class="ok">&#10003; Conectado. Endereco do NAS fora de casa: <b>${esc(t.ip)}</b></p><p>No celular ou PC, instale o app <b>Tailscale</b> e entre com a mesma conta.</p>`;return}
  if(!t.instalado||!e.base_ok){d.innerHTML="<p>Fica disponivel quando a instalacao terminar.</p>";return}
  let h="<p>Permite acessar o NAS de qualquer lugar, com seguranca, sem abrir portas no roteador.</p>";
  if(t.url){h+=`<p>1. Abra este link e entre na sua conta Tailscale (pode criar uma gratis com Google ou Microsoft):</p>
    <p><a href="${esc(t.url)}" target="_blank" rel="noopener">${esc(t.url)}</a></p><p>Ou aponte a camera do celular:</p><div class="qr">${t.qr||""}</div>
    <p>2. Depois do login, esta pagina mostra "Conectado".</p>`}
  else{h+=`<button id="b-ts" ${t.rodando?"disabled":""}>${t.rodando?"Gerando link...":"Conectar ao Tailscale"}</button>`}
  if(t.erro)h+=`<div class="msg err">${esc(t.erro)}</div>`;
  d.innerHTML=h;const b=$("b-ts");if(b)b.onclick=()=>post("/api/tailscale").then(atualizar);
}
const ESTADOS={em_uso:["Em uso","ok"],vazio:["Novo - sera preparado","and"],preparando:["Preparando","and"],com_dados:["Tem dados","err"],em_uso_outro:["Montado fora do NAS","pen"]};
function discos(e){
  const ds=e.discos||[];let h="";
  if(!e.base_ok)h="<p>Pode conectar os discos agora ou depois. Eles aparecem aqui logo, mas so serao usados quando a instalacao terminar.</p>";
  if(!ds.length)h+="<p>Nenhum disco conectado. Conecte um SSD ou HD numa porta <b>USB 3.0 (azul)</b> da placa. Ele aparece aqui em ate 1 minuto.</p>";
  if(e.usb_problema)h+=`<div class="msg err">Algo foi ligado numa porta USB e nao respondeu direito. Se for um <b>HD de disco</b>, provavelmente falta energia: use um <b>hub USB com fonte</b> (ou um HD com fonte propria) e uma fonte de 5 V / 3 A na placa. Tambem vale testar outro cabo e a porta USB 3.0 (azul).</div>`;
  for(const d of ds){const [t,c]=ESTADOS[d.estado]||[d.estado,"pen"];
    h+=`<div class="disco"><b>${esc(d.modelo||"Disco")}</b> ${esc(d.tamanho)} <span class="tag ${c}">${t}</span><br><small>${esc(d.dev)} - ${esc(e.base_ok?d.papel:"Sera usado quando a instalacao terminar")}</small>`;
    if(d.estado==="com_dados"){h+=`<br><small>Este disco ja tem dados e NAO sera apagado sozinho.</small>`;
      h+=e.base_ok?`<br><button class="perigo" data-dev="${esc(d.dev)}">Apagar e usar este disco</button>`:`<br><small>Quando a instalacao terminar, aparece aqui o botao para apagar e usar este disco.</small>`}
    h+="</div>"}
  $("discos").innerHTML=h;
  document.querySelectorAll("button[data-dev]").forEach(b=>b.onclick=async()=>{
    const c=prompt("ATENCAO: tudo o que estiver em "+b.dataset.dev+" sera APAGADO.\nPara confirmar, digite APAGAR:");
    if(c!=="APAGAR")return;try{await post("/api/formatar",{dev:b.dataset.dev,confirmacao:c});alert("Preparando o disco. Acompanhe nesta pagina.")}catch(err){alert(err.message)}});
  const nc={aguardando_disco:"Nextcloud: sera criado quando houver um disco.",instalando:"Nextcloud: instalando (alguns minutos)...",pronto:"Nextcloud: pronto."}[e.nextcloud]||"";
  $("nc").textContent=e.etapa_nextcloud==="erro"?"Nextcloud: houve um problema, o NAS vai tentar de novo sozinho.":nc;
}
function enderecos(e){
  const a=e.enderecos,t=e.tailscale;let l=[["Esta pagina",a.pagina],["Arquivos (Windows)",a.smb_win],["Arquivos (Mac/Linux)",a.smb_mac],["Painel do OMV (usuario admin)",a.omv]];
  if(e.nextcloud==="pronto")l.splice(1,0,["Nextcloud",a.nextcloud]);
  if(t.conectado){l.push(["Fora de casa: Nextcloud",`http://${t.ip}:8081`],["Fora de casa: arquivos",`\\\\${t.ip}\\dados`])}
  $("end").innerHTML=l.map(([k,v])=>`<tr><td>${esc(k)}</td><td>${v.startsWith("http")?`<a href="${esc(v)}" target="_blank">${esc(v)}</a>`:esc(v)}</td></tr>`).join("")+
   `<tr><td>Usuario</td><td>${esc(e.usuario)} (e a senha que voce criou)</td></tr>`;
}
async function atualizar(){
  try{const r=await fetch("/api/estado",{cache:"no-store"});if(r.status===401){location.reload();return}
    const e=await r.json();mostra("conexao",false);
    mostra("c-config",!e.configurado);mostra("c-inst",e.configurado);mostra("c-ts",e.configurado);
    mostra("c-discos",true);mostra("c-end",e.base_ok);
    if(e.configurado){etapas(e);tailscale(e)}discos(e);if(e.base_ok)enderecos(e);
  }catch(err){mostra("conexao",true)}
}
atualizar();setInterval(atualizar,3000);
</script></body></html>
"""


class ServidorDuplo(ThreadingHTTPServer):
    """Escuta em IPv4 e IPv6 ao mesmo tempo. Necessario porque, depois que o
    OpenMediaVault configura o avahi, o nome nas.local pode responder so com
    o endereco IPv6 da placa."""
    address_family = socket.AF_INET6

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


def criar_servidor(porta):
    try:
        return ServidorDuplo(("::", porta), Pagina)
    except OSError:
        return ThreadingHTTPServer(("", porta), Pagina)   # sem IPv6 na placa


def avisar_led_pronto():
    """LED de status aceso fixo = a pagina ja abre. So depois que o 1o boot
    terminou; se ele falhou (sem internet), o LED continua piscando devagar."""
    if os.path.exists("/var/lib/nas-instalador/preparado"):
        rodar("/usr/local/sbin/nas-led", "pronto", timeout=15)


def main():
    global servidor80
    principal = criar_servidor(PORTA)
    if not configurado():
        try:
            servidor80 = criar_servidor(80)
            threading.Thread(target=servidor80.serve_forever, daemon=True).start()
        except OSError:
            servidor80 = None
    avisar_led_pronto()
    principal.serve_forever()


if __name__ == "__main__":
    main()
