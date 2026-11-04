# terminal-googlebook

Una Googlebook virtual para agentes de IA: Googlebook OS en una VM de tu Mac Apple Silicon, sin ventana y aislada del escritorio, controlable por CLI y MCP. Une [terminal-mac](https://github.com/govijr/terminal-mac) (CLI, MCP) y [gbos-vm](https://github.com/skylartaylor/gbos-vm) (VM, GPU, helper de puntero), ambos MIT. `vm/` es gbos-vm.

**Estado:** Fases 1 a 3 listas en una sola Mac; repo privado por ahora. Ver [PRD](docs/PRD.md) y [validación](docs/VALIDATION.md).

## Instalar

Requiere Apple Silicon, macOS 26 o superior, 16 GB de RAM y 60 GB libres. No pide `sudo`, Xcode ni Homebrew.

```bash
curl -fsSL https://github.com/masteread/terminal-googlebook/releases/latest/download/get.sh | bash
```

Instala en `~/.local` y no toca tu shell: si `~/.local/bin` no está en tu `PATH`, agrégalo. Usa `curl`: el paquete tiene firma ad-hoc, sin notarizar, y macOS lo rechaza si lo bajas con el navegador. `get.sh` verifica su SHA-256.

## Usar

```bash
terminal-googlebook doctor                # comprueba esta Mac
terminal-googlebook up                    # la primera vez descarga unos 9 GB de Google y UTM
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

Para agentes: [docs/AGENT.md](docs/AGENT.md).

No sirve para cuentas ni datos sensibles: la VM no tiene hardware seguro y, salvo con `--offline`, puede alcanzar servicios del host y la LAN. Nada de Google se redistribuye: la imagen se descarga y verifica en tu máquina.

Licencia MIT, salvo `vm/patches/cocoaspice-viewer.patch` (Apache-2.0). El paquete del release incluye binarios de terceros con otras licencias, GPL entre ellas: ver [THIRD_PARTY.md](THIRD_PARTY.md).
