# NAS doméstico

Transforma uma **Radxa ROCK 4B+** num servidor NAS doméstico com **OpenMediaVault 8**,
compartilhamento de arquivos (SMB), **Nextcloud** (nuvem privada) e **Tailscale** (acesso de fora
de casa), **sem monitor e sem digitar comandos**: grave o microSD, ligue a placa e configure tudo
pelo navegador do PC ou do celular.

> Projeto desenvolvido como Trabalho de Conclusão de Curso (Ciência da Computação, Universidade
> Tuiuti do Paraná, 2026): *Análise da viabilidade técnica de um servidor NAS doméstico de baixo
> custo baseado em um Single Board Computer, OpenMediaVault, Nextcloud e Tailscale*.

## Como usar (5 passos)

1. **Baixe a imagem** na [versão mais recente](../../releases/latest): arquivo `nas-domestico-rock4bplus-*.img.xz`.
2. **Grave no microSD** (16 GB ou mais) com o [balenaEtcher](https://etcher.balena.io/).
   Se o Windows pedir para formatar o cartão depois, clique em **Cancelar**.
3. **Ligue a placa** com o microSD, o **cabo de rede** e a fonte. Aguarde 10 a 15 minutos
   (com a tela OLED opcional, espere aparecer **PRONTO!** com o endereço e o IP).
4. **Abra `http://nas.local:8000`** no PC ou no celular (ou `http://IP-DA-PLACA:8000`),
   crie seu usuário e senha e clique em **Começar instalação** (20–40 min).
5. **Plugue o SSD** numa porta USB 3.0 (azul) e, se quiser, clique em
   **Conectar ao Tailscale** para acessar de fora de casa.

O passo a passo completo, com o que acontece em cada situação, endereços e solução de problemas, está no
**[GUIA-NAS.md](GUIA-NAS.md)**.

## O que você ganha

| Serviço | Para que serve |
|---|---|
| Página do NAS (`:8000`) | Configuração inicial, andamento da instalação, SSDs, Tailscale e endereços |
| Arquivos na rede (SMB) | Pasta `\\IP-DA-PLACA\dados` no Windows/Mac/Linux |
| Nextcloud (`:8081`) | Nuvem privada no navegador e no app (backup de fotos do celular) |
| OpenMediaVault (`:80`) | Painel avançado do NAS (seu usuário entra como administrador) |
| Tailscale | Acesso seguro de qualquer lugar, sem abrir portas no roteador |

### SSDs

- **SSD vazio** → preparado automaticamente.
- **SSD formatado pelo painel do OMV** → usado automaticamente.
- **SSD com dados** → **nunca é apagado sozinho**; a página mostra um botão que exige digitar `APAGAR`.
- Sem SSD, o Nextcloud fica desligado de propósito, para nunca gravar dados no microSD.

## Para desenvolvedores

A imagem é o **Armbian oficial** (Debian 13 "trixie", Minimal/CLI) com os arquivos de
[`arquivos/`](arquivos) colocados dentro. Para gerar uma nova (Linux ou WSL2, como root):

```bash
sudo bash gerar-imagem.sh        # cria saida/nas-tcc.img a partir do Armbian oficial (SHA-256 conferido)
```

Também é possível instalar num Armbian trixie já em uso, pelo terminal:

```bash
sudo bash arquivos/instalar-nas.sh             # pergunta usuário/senha e instala tudo
sudo instalar-nas.sh --verificar               # confere a instalação
```

| Arquivo | Função |
|---|---|
| `gerar-imagem.sh` | Baixa o Armbian oficial, confere o SHA-256 e injeta os arquivos do NAS |
| `arquivos/instalar-nas.sh` | Instalador: base (OMV, SMB, Docker, Tailscale), organizador de SSDs, Nextcloud, backup, verificação |
| `arquivos/nas-assistente.py` | Página de configuração/painel (porta 8000, só biblioteca padrão do Python) |
| `arquivos/nas-preparar.sh` | Primeiro boot: bloqueia `root`/`1234`, desliga o autologin e instala o necessário |
| `arquivos/nas-oled.py` | Tela OLED opcional (0,96" SSD1306 I2C): mostra PRONTO!, IP, andamento e discos |
| `arquivos/instalar-oled.sh` | Instala só a tela OLED num NAS que já está funcionando, sem apagar nada |
| `arquivos/u-boot/` | Bootloader da imagem (U-Boot v2025.01 com I2C) e o script que o recompila |
| `arquivos/*.service` | Serviços systemd do primeiro boot, da página e da instalação base |

Detalhes da arquitetura, ordem dos serviços e decisões de segurança: [GUIA-NAS.md](GUIA-NAS.md#3-para-os-desenvolvedores-como-a-imagem-é-gerada).

## Estado do projeto

- Testado na Radxa ROCK 4B+ (4 GB) com Armbian 26.8.1 trixie: instalação base completa pela
  página (OpenMediaVault, SMB, Docker e Tailscale).
- Versão 2.0 incorpora as correções do primeiro teste (página acessível por IPv6 em `nas.local`
  e usuário como administrador do OMV).
- Versão 2.1: tela OLED opcional (0,96" SSD1306) com o estado do NAS. Testada na placa: com o
  U-Boot do NAS (com I2C, em [`arquivos/u-boot`](arquivos/u-boot)), a tela mostra "LIGANDO" cerca
  de 4 segundos depois de ligar a energia, antes do Linux.
- Outras placas com Armbian trixie devem funcionar trocando a URL em `gerar-imagem.sh`, mas não
  foram testadas.
