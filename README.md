# terminal-googlebook

Una Googlebook virtual para agentes de IA: Googlebook OS en una VM de tu Mac Apple Silicon, sin ventana y aislada del escritorio, controlable por CLI y MCP. Une [terminal-mac](https://github.com/govijr/terminal-mac) (CLI, MCP) y [gbos-vm](https://github.com/skylartaylor/gbos-vm) (VM, GPU, helper de puntero), ambos MIT. `vm/` es gbos-vm.

**Estado:** Fase 1 lista; viewer e instalador pendientes. Ver [PRD](docs/PRD.md) y [validación](docs/VALIDATION.md).

Hoy requiere compilar desde el repositorio, con Homebrew, Android SDK y Xcode:

```bash
cd vm && ./install.sh && cd ..
bash scripts/build.sh
dist/terminal-googlebook up
dist/terminal-googlebook action open_url https://example.com
dist/terminal-googlebook action screenshot --output /tmp/guest.png
dist/terminal-googlebook stop
```

Para agentes: [docs/AGENT.md](docs/AGENT.md).

No sirve para cuentas ni datos sensibles: la VM no tiene hardware seguro y, salvo con `--offline`, puede alcanzar servicios del host y la LAN. Nada de Google se redistribuye: la imagen se descarga y verifica en tu máquina.

Licencia MIT, salvo `vm/patches/cocoaspice-viewer.patch` (Apache-2.0).
