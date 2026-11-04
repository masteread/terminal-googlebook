# terminal-googlebook

Una Googlebook virtual para agentes de IA: Googlebook OS en una VM de tu Mac Apple Silicon, sin ventana y aislada del escritorio, controlable por CLI y MCP.

**Estado:** Fases 1 a 3 listas; validado en una sola Mac, falta una segunda. Ver [PRD](docs/PRD.md) y [validación](docs/VALIDATION.md).

## Proyectos originales

Este proyecto existe gracias a dos proyectos MIT:

- [terminal-mac](https://github.com/govijr/terminal-mac), de Govijr: el proyecto original, que corre macOS entero en tu terminal. De ahí vienen la CLI, el servidor MCP y el viewer.
- [gbos-vm](https://github.com/skylartaylor/gbos-vm), de Skylar Taylor: la VM de Googlebook OS en Mac, con GPU y helper de puntero. `vm/` es gbos-vm.

## Instalar

Requiere Apple Silicon, macOS 26 o superior, 16 GB de RAM y 60 GB libres. No pide `sudo`, Xcode ni Homebrew.

```bash
curl -fsSL https://github.com/masteread/terminal-googlebook/releases/latest/download/get.sh | bash
```

Instala en `~/.local` y no toca tu shell: si `~/.local/bin` no está en tu `PATH`, agrégalo. Usa `curl`: el paquete tiene firma ad-hoc, sin notarizar, y macOS lo rechaza si lo bajas con el navegador. `get.sh` verifica su SHA-256.

## Usar

```bash
terminal-googlebook doctor                # comprueba esta Mac
terminal-googlebook setup                 # descarga unos 9 GB de Google y UTM; si se corta, córrelo otra vez
terminal-googlebook up                    # abre el viewer
terminal-googlebook action open_url https://example.com
terminal-googlebook action screenshot --output /tmp/guest.png
terminal-googlebook stop
```

Solo puede correr una VM a la vez.

## Compilar desde el repositorio

Requiere Homebrew, Android SDK y Xcode:

```bash
cd vm && ./install.sh && cd ..
bash scripts/build.sh
dist/terminal-googlebook up
```

`VERSION=x.y.z BUILD_NUMBER=N bash scripts/release.sh` arma el paquete del release en `dist/releases/`.

## Darle su máquina a un agente y verlo en vivo

Conecta tu agente una vez:

```bash
claude mcp add --scope user terminal-googlebook -- terminal-googlebook mcp
terminal-googlebook skills install
terminal-googlebook setup          # solo la primera vez: unos 9 GB, con barra de progreso y reporte de tiempo
```

Después, en cualquier conversación nueva, pídele una tarea: el agente enciende su máquina con la tool `start`.

Para mirarlo, abre otra pestaña en Ghostty, Kitty o iTerm2. Puedes hacerlo antes de darle la tarea, porque espera a que la VM encienda:

```bash
terminal-googlebook view
```

Ves la pantalla, el puntero del agente con un anillo en cada click, y su última acción en el pie. También puedes usar la VM tú mismo. `Ctrl+]` cierra el viewer y deja la VM encendida; `terminal-googlebook stop` la apaga.

Para agentes: [docs/AGENT.md](docs/AGENT.md).

No sirve para cuentas ni datos sensibles: la VM no tiene hardware seguro y, salvo con `--offline`, puede alcanzar servicios del host y la LAN. Nada de Google se redistribuye: la imagen se descarga y verifica en tu máquina.

Licencia MIT, salvo `vm/patches/cocoaspice-viewer.patch` (Apache-2.0). El paquete del release incluye binarios de terceros con otras licencias, GPL entre ellas: ver [THIRD_PARTY.md](THIRD_PARTY.md).
