# NAS doméstico com instalação automática

Este guia explica como funciona a **imagem pronta do NAS**: um arquivo de sistema que se grava
no microSD da Radxa ROCK 4B+. A placa se instala sozinha, e o usuário configura tudo pelo
navegador do próprio PC ou celular, **sem monitor e sem comandos**.

---

## 1. A ideia em uma figura

```
  PC ou celular do usuário                     ROCK 4B+ (sem monitor)
 ┌───────────────────────────┐   rede de casa  ┌──────────────────────────────┐
 │ navegador:                 │ ◀────────────▶ │ microSD com a imagem do NAS  │
 │  http://nas.local:8000     │                 │  - instala OMV, Docker, ...  │
 │  - cria usuário e senha    │                 │  - serve a página de config. │
 │  - conecta o Tailscale     │                 │  - organiza os SSDs plugados │
 │  - vê os SSDs e endereços  │                 └──────────────────────────────┘
 └───────────────────────────┘
```

A página é aberta no navegador do PC ou do celular, do mesmo jeito que se configura um
roteador ou o painel do OpenMediaVault. A placa só precisa do **cabo de rede** e da **energia**.

---

## 2. Passo a passo para o usuário

1. **Gravar o microSD.** Baixe a imagem na página de **Releases** do repositório
   (`nas-domestico-rock4bplus-*.img.xz`) e use o [balenaEtcher](https://etcher.balena.io/):
   - escolha o arquivo baixado (não precisa descompactar) e o cartão;
   - clique em *Flash*.
   - Se o Windows depois disser *"Você precisa formatar o disco"*, clique em **Cancelar**. É normal:
     o Windows não lê o formato Linux do cartão.
2. **Ligar a placa.** Coloque o microSD, ligue o **cabo de rede** no roteador e depois a **fonte**.
   Os SSDs podem ficar desligados por enquanto.
3. **Esperar de 10 a 15 minutos, sem desligar.** No primeiro boot, a placa ajusta o sistema e
   baixa o que precisa para mostrar a página. Com a **tela OLED** (opcional, veja abaixo), é só
   esperar aparecer **PRONTO!**: ela mostra o endereço e o IP para abrir no navegador.
4. **Abrir a página.** No PC ou no celular, conectado à mesma rede, abra:
   **`http://nas.local:8000`**
   - Se não abrir, descubra o IP da placa na lista de aparelhos do roteador, ou com o app gratuito
     **Fing** no celular. Depois abra `http://IP-DA-PLACA:8000`, por exemplo `http://192.168.0.16:8000`.
5. **Criar o acesso.** Escolha um nome de usuário (letras minúsculas, sem espaços) e uma senha
   (mínimo de 8 caracteres) e clique em **Começar instalação**. Esse usuário e essa senha servem
   para tudo: arquivos na rede, Nextcloud, esta página e o painel do OMV. No painel, o seu usuário
   já entra como administrador (grupo `openmediavault-admin`); o usuário `admin` recebe a mesma senha.
6. **Fazer login.** O navegador pede usuário e senha. Use os que você acabou de criar.
7. **Aguardar de 20 a 40 minutos.** A página mostra cada etapa: sistema, OpenMediaVault, usuário
   e compartilhamento, Docker, Tailscale. Pode fechar a página e voltar depois.
8. **Conectar o Tailscale** (opcional, para acessar fora de casa). Clique em
   **Conectar ao Tailscale**. Abra o link (ou aponte a câmera para o QR code) e entre na sua conta
   Tailscale. Ela é gratuita e pode ser criada com Google ou Microsoft. No celular ou notebook que
   vai acessar o NAS de fora, instale o app Tailscale e entre na mesma conta.
9. **Conectar os SSDs** nas portas **USB 3.0 (azuis)**, a qualquer momento. Eles aparecem na
   página em até 1 minuto.

### Tela OLED (opcional)

Uma telinha OLED **0,96" 128x64 I2C de 4 pinos** (controlador SSD1306, por exemplo a
**GM009605**) mostra o estado do NAS sem precisar de monitor. Ligue com a placa **desligada**:

| Pino da tela | Pino da ROCK 4B+ (barra de 40 pinos) |
|---|---|
| GND | **6** (GND) |
| VCC | **1** (3,3 V) — **não** use os pinos 2 ou 4 (5 V) |
| SCL | **5** (I2C7_SCL) |
| SDA | **3** (I2C7_SDA) |

| A tela mostra | Significado |
|---|---|
| LIGANDO | A placa está iniciando (aparece ~4 s depois de ligar a energia) |
| SEM REDE | Só aparece se, 3 minutos depois de ligar, a placa ainda não entrou na rede |
| PREPARANDO | Primeiro boot: aguarde e não desligue |
| SEM NET | Está na rede, mas sem internet há mais de 3 minutos |
| **PRONTO!** | **Abra o endereço mostrado no navegador** e crie o usuário |
| INSTALANDO | Etapa atual (1 a 5) e barra de progresso |
| ERRO | Abra a página e clique em *Tentar de novo* |
| NAS OK | Endereço, IP da rede, **IP do Tailscale**, quantos discos e o Nextcloud |

Sem a tela, tudo funciona igual. Depois de 10 minutos sem mudança, o brilho baixa para
poupar o OLED.

**Num NAS que já está funcionando** (por exemplo, montado à mão, sem esta imagem), a tela pode
ser instalada sem apagar nada. Com a placa ligada e acessada por SSH:

```bash
curl -fsSL https://raw.githubusercontent.com/emannoel-2023/nas-domestico/main/arquivos/instalar-oled.sh | sudo bash
sudo reboot
```

Ele só copia o programa da tela e liga o I2C7 no `/boot/armbianEnv.txt` (guardando uma cópia
em `armbianEnv.txt.antes-oled`). Nesse modo, a tela mostra o nome da placa, o IP, o IP do
Tailscale, quantos discos estão ligados e os tamanhos. Para desfazer, rode o mesmo comando com
`| sudo bash -s -- --remover`. O "LIGANDO" em 4 segundos depende do U-Boot do NAS e não é
instalado por esse comando; sem ele, a tela acende quando o Linux começa.

### O que acontece com cada SSD

| Situação do SSD | O que o NAS faz |
|---|---|
| **Novo / vazio** (sem partições) | Prepara sozinho: formata em ext4, registra no OMV e cria as pastas |
| **Formatado pelo painel do OMV** | Usa sozinho, sem apagar nada |
| **Com dados** | **Nunca apaga sozinho.** Mostra o aviso "Tem dados" e um botão *Apagar e usar este disco*, que pede para digitar `APAGAR`. Também dá para formatar pelo painel do OMV (Armazenamento → Discos) |

- **O primeiro SSD** recebe tudo: a pasta de arquivos `dados` (SMB) e o Nextcloud.
- **Dois SSDs conectados juntos**: o maior fica com os arquivos (SMB) e o outro com o Nextcloud,
  como no protótipo do TCC.
- **SSDs conectados depois** viram pastas extras (`disco2`, `disco3`...).
- **Sem nenhum SSD**, o Nextcloud fica desligado de propósito, para nunca gravar dados no microSD.

### Endereços depois de pronto (a página mostra todos)

| Serviço | Endereço |
|---|---|
| Página do NAS | `http://nas.local:8000` |
| Arquivos no Windows | `\\IP-DA-PLACA\dados` (no Explorador de Arquivos) |
| Arquivos no Mac/Linux | `smb://IP-DA-PLACA/dados` |
| Nextcloud | `http://IP-DA-PLACA:8081` (e o app Nextcloud no celular) |
| Painel do OpenMediaVault | `http://IP-DA-PLACA` (seu usuário, ou `admin`; mesma senha) |
| Fora de casa | os mesmos endereços com o IP do Tailscale (`100.x.x.x`) |

> Dica: reserve o IP da placa no roteador (DHCP fixo / reserva de IP), para o endereço não mudar.

---

## 3. Para os desenvolvedores: como a imagem é gerada

A imagem é o **Armbian oficial** da ROCK 4B+ (Debian 13 "trixie", versão Minimal/CLI) com os
nossos arquivos colocados dentro. Nada é recompilado.

```bash
sudo bash gerar-imagem.sh            # gera saida/nas-tcc.img e nas-tcc.img.sha256
```

- Roda em qualquer Linux como root: WSL2 no Windows, um PC Linux ou a própria ROCK 4B+.
- Baixa `https://dl.armbian.com/rockpi-4bplus/Trixie_current_minimal`, confere o SHA-256 oficial,
  monta a partição do sistema e copia os arquivos.
- Para usar outra versão do Armbian: `ARMBIAN_URL=... sudo -E bash gerar-imagem.sh`.

### Arquivos do projeto

```
nas-imagem/
├── gerar-imagem.sh            cria a imagem a partir do Armbian oficial
├── GUIA-NAS.md                este guia
└── arquivos/                  o que vai para dentro da imagem
    ├── instalar-nas.sh        instalador (base, organizador de SSDs, verificação)
    ├── nas-assistente.py      página de configuração/painel (porta 8000, só Python padrão)
    ├── nas-preparar.sh        1º boot: segurança + pacotes da página
    ├── nas-oled.py            tela OLED opcional (SSD1306, I2C 7; só Python padrão)
    ├── nas-oled.service       mantém a tela atualizada (encerra se não houver tela)
    ├── nas-preparar.service   roda o nas-preparar.sh uma vez
    ├── nas-assistente.service mantém a página no ar
    └── nas-base.service       instalação base (continua sozinha se a placa reiniciar)
```

### O que roda na placa, em ordem

1. **`nas-preparar`** (só no primeiro boot):
   - bloqueia o login de `root` (o Armbian vem com a senha `1234`);
   - desliga o assistente de primeiro login e o login automático do console;
   - instala `python3`, `avahi-daemon` (para o nome `nas.local`) e `qrencode`.
2. **`nas-assistente`** (sempre ativo):
   - mostra a página na porta **8000**;
   - na porta 80, só redireciona para a 8000, e apenas até a configuração (depois a porta 80
     passa a ser do painel do OMV);
   - depois do cadastro, exige usuário e senha (HTTP Basic, senha guardada como PBKDF2).
3. **`nas-base`**, iniciado quando o usuário clica em *Começar instalação*, roda
   `instalar-nas.sh --base`:
   - pacotes;
   - OpenMediaVault, pelo instalador oficial com `-n`, que não altera a rede;
   - usuário, senha, SMB e senha do `admin` do OMV;
   - Docker;
   - Tailscale (só instala; o login é pelo botão).
4. **`nas-organizador`** (timer a cada 30 s) roda `instalar-nas.sh --organizar`:
   - detecta SSDs, prepara os vazios e adota os montados pelo OMV;
   - cria as pastas e compartilhamentos e sobe o Nextcloud;
   - liga o cron, o watchdog e o backup de configuração.
5. **`nas-oled`** (sempre ativo, desde o boot): procura uma tela SSD1306 em `/dev/i2c-7`
   (endereço 0x3C ou 0x3D) e mostra o estado lendo os mesmos arquivos da página. A imagem liga o
   barramento com `overlays=rk3399-i2c7` no `/boot/armbianEnv.txt` e o módulo `i2c-dev`. Para ver
   as telas sem a placa: `python3 arquivos/nas-oled.py --previa pasta/` gera um PNG de cada uma.

**Bootloader (U-Boot) do NAS.** O U-Boot que vem no Armbian não tem o comando `i2c`, então a tela
só acenderia quando o Linux começasse (~25 s). A imagem usa um U-Boot v2025.01 (com TF-A v2.12.0)
recompilado por `arquivos/u-boot/compilar-u-boot.sh`, igual ao oficial da ROCK Pi 4 com três
mudanças: comando `i2c`, I2C7 ligado e `BOOTDELAY=0`. O `gerar-imagem.sh`:

- grava `idbloader.img` no setor 64 e `u-boot.itb` no setor 16384 (antes da partição, no 32768);
- põe no começo do `/boot/boot.cmd` o bloco `arquivos/u-boot/boot-oled.cmd`, que manda a tela
  "LIGANDO" (`/boot/nas-oled-ligando.bin`, gerada por `nas-oled.py --quadro-ligando`) por I2C, e
  recompila o `boot.scr`;
- trava (`hold`) o pacote `linux-u-boot-*` do Armbian, para uma atualização não trocar o U-Boot.

Resultado na placa: "LIGANDO" aparece ~4 s depois de ligar a energia. Sem tela, ou com outro
U-Boot, os comandos falham em silêncio e o boot segue normal.

O progresso fica em `/var/lib/nas-instalador/progresso.json`, que a página lê, e o log completo
em `/var/log/nas-instalador.log`.

### Também funciona sem a imagem (pelo terminal)

Num Armbian trixie comum, com acesso por SSH:

```bash
sudo bash instalar-nas.sh              # pergunta usuário/senha e instala tudo
sudo instalar-nas.sh --verificar       # confere a instalação
sudo instalar-nas.sh --formatar /dev/sdX   # apaga um disco com dados e o usa
```

---

## 4. Correções do protótipo que já vêm na imagem

Problemas encontrados no microSD do protótipo e como a instalação automática os evita:

| Problema no protótipo | Solução na imagem |
|---|---|
| Nextcloud gravou ~4 GB no microSD por causa de um UUID antigo | Volumes sempre em `/srv/dev-disk-by-uuid-<UUID>` do SSD montado; o `--verificar` confere |
| Em 25/09/2026, o SSD não montou no boot e o Nextcloud recriou os arquivos no microSD | O Docker só inicia com o SSD montado (`RequiresMountsFor`) |
| O SSD USB cai e volta; os contêineres ficam com "Input/output error" | Watchdog a cada 1 min, que só reinicia quando o SSD está montado de novo |
| O backup poderia gravar no cartão se o SSD estivesse ausente | O backup é cancelado se algum SSD não estiver montado |
| Incompatibilidade do Tailscale com nftables | Tailscale no host com `netfilter-mode=off` (configuração validada no TCC) |
| `tailscale0` registrado como interface no OMV | O instalador não mexe na rede (`-n`) |
| Senha padrão `root`/`1234` e `admin`/`openmediavault` | `root` bloqueado; `admin` recebe a senha do usuário |
| (1º teste da imagem) `nas.local` passou a responder só em IPv6 depois do OMV | A página escuta em IPv4 e IPv6 |
| (1º teste da imagem) o usuário entrava no painel do OMV sem permissão | O usuário entra no grupo `openmediavault-admin` |

---

## 5. Problemas comuns

| Sintoma | O que fazer |
|---|---|
| `nas.local` não abre | Espere 10 min no primeiro boot. Use o IP da placa (roteador ou app Fing) com `:8000` |
| A página não abre nem pelo IP | Confira o cabo de rede e se a placa tem internet. Sem internet, o primeiro boot não termina e tenta de novo no próximo boot |
| Etapa com ✗ vermelho | Clique em **Tentar de novo**. Os detalhes técnicos ficam no fim da caixa *Instalação* |
| O SSD aparece como "Tem dados" | É proteção: use *Apagar e usar este disco* (apaga tudo) ou o painel do OMV |
| O Nextcloud demora | No primeiro uso, ele baixa as imagens e cria o banco: de 5 a 15 minutos no microSD |
| Esqueci a senha | Pelo painel do OMV (`admin`) ou por SSH com o usuário criado (ele tem `sudo`) |

### Segurança: o que saber

- **Até alguém fazer o cadastro, qualquer aparelho da rede de casa pode abrir a página** e criar o
  usuário (como em roteadores novos). Faça o cadastro logo depois de ligar.
- Depois do cadastro, a página exige usuário e senha. A senha do Nextcloud é apagada do disco assim
  que o Nextcloud é criado.
- Nenhuma porta é aberta no roteador: o acesso de fora é só pelo Tailscale.

---

## 6. Limitações e o que ainda precisa de teste

- Validado em sintaxe e lógica: `bash -n`, ShellCheck sem avisos, a página testada no navegador
  e a detecção de discos testada com dados simulados.
- Testado na ROCK 4B+: primeiro boot, página, instalação base, detecção de SSD/HD e tela OLED
  (com o U-Boot do NAS). Os registros ficam em `/var/log/nas-preparar.log` e
  `/var/log/nas-instalador.log`.
- O LED azul de status desta placa não funcionou; por isso o sinal de "pronto" é a tela OLED
  (opcional) ou esperar de 10 a 15 minutos.
- A imagem `nextcloud:apache` acompanha a versão mais nova do Nextcloud. Para fixar uma versão,
  edite `NC_IMAGE` no `instalar-nas.sh` antes de gerar a imagem.
- Feito para a ROCK 4B+. Outras placas com Armbian trixie devem funcionar trocando a URL em
  `gerar-imagem.sh`, mas não foram testadas.
