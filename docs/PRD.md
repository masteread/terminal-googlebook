# PRD: terminal-googlebook

Nov 3, 2026

## 1. Visión

terminal-googlebook da a un agente de IA (Claude Code u otro cliente MCP) su propia laptop Googlebook virtual, aislada del escritorio del Mac host, visible y controlable desde la terminal. Es [terminal-mac](https://github.com/govijr/terminal-mac) con otro guest: misma CLI, mismas tools MCP, misma skill de observe → act → verify.

El guest es una VM de **Googlebook OS** (el OS oficial de Google para laptops, ARM64, basado en Android 17, lanzado el 4 de octubre de 2026). No es Chrome OS ni Chrome OS Flex, que son otra plataforma basada en Linux. La VM corre sobre [gbos-vm](https://github.com/skylartaylor/gbos-vm), que arranca la imagen de recuperación oficial de Google bajo QEMU con GPU acelerada vía Metal y Chrome funcionando.

Principio de diseño: **reutilizar, no reconstruir**. gbos-vm ya resuelve la VM, la GPU y el puntero; terminal-mac ya resuelve el viewer en terminal, el protocolo de acciones y la integración con agentes. Este proyecto es la capa de pegamento entre los dos más un modo headless. Todo lo que no sea necesario para que un agente abra Chrome, navegue, haga click y escriba, queda fuera de v1.

## 2. Alcance v1

v1 es lo mínimo para que un agente use una Googlebook virtual de punta a punta: crear la VM, verla en la terminal y operarla por MCP.

**In scope**

- VM de Googlebook OS sobre gbos-vm, en Mac Apple Silicon
- Modo headless: la VM corre sin ventana visible en el host
- Captura de pantalla e inyección de input desde el host (sin app dentro de Android)
- Servidor MCP stdio con las mismas tools que terminal-mac más las propias de Android
- CLI `terminal-googlebook` con `up`, `start`, `stop`, `status`, `action`, `mcp`, `view`
- Viewer en terminal (Kitty, Ghostty, iTerm2) reutilizando el de terminal-mac
- Skill y plugin para Claude Code
- Instalador `curl | bash` con binarios precompilados; solo la imagen de Google se descarga localmente

**Out of scope (v1)**

- Mac Intel, Chrome OS, Chrome OS Flex
- Múltiples VMs simultáneas (el layout de disco sí deja la puerta abierta, pero no se implementa)
- Bluetooth, audio y clipboard bidireccional
- Google Play, cuentas de Google, provisioning desatendido
- Snapshot de árbol de accesibilidad (`snapshot` es alias de `screenshot`, como en terminal-mac)
- tmux, splits de terminal, checkpoints de VM
- Cualquier dependencia de ADB en el camino crítico

## 3. Arquitectura

La diferencia clave con terminal-mac: **el host ya tiene los frames del guest**. En macOS, Apple Virtualization no expone el framebuffer, por eso terminal-mac necesita un helper dentro del guest con permisos de Screen Recording. En gbos-vm el guest renderiza vía virglrenderer sobre Metal en el proceso de QEMU del host, así que screenshot y stream salen del host sin pedir nada a Android. El guest solo necesita el pointer helper que gbos-vm ya incluye.

| Capa | terminal-mac | terminal-googlebook |
| --- | --- | --- |
| Virtualización | Apple Virtualization.framework | QEMU (fork de UTM) + Hypervisor.framework, vía gbos-vm |
| Guest OS | macOS | Googlebook OS (Android 17, imagen oficial Dell) |
| Captura de pantalla | Helper en guest (ScreenCaptureKit) | Host: framebuffer del renderer o QMP `screendump` |
| Teclado | Helper en guest | Host: QMP `input-send-event` (teclado virtio) |
| Puntero | Helper en guest | Pointer helper de gbos-vm (tableta virtual, corre como `shell`, token por boot) |
| Transporte host ↔ guest | virtio-fs + mailbox JSON | Socket Unix local (el que ya usa gbos-vm) |
| Viewer en terminal | Kitty / Ghostty / iTerm2, lz4 + shared memory | Mismo código, misma entrada de frames |
| MCP + CLI | Swift Package | Swift Package (fork del de terminal-mac) |

&#91;embedded content: arquitectura · host y guest, 6 componentes\]

Screenshot y teclado van por QMP al proceso de QEMU; solo el puntero entra al guest, por el helper que gbos-vm ya trae. Nada toca las APIs de input o pantalla del host.

## 4. Requisitos funcionales

### 4.1 Ciclo de vida de la VM

- `terminal-googlebook up [NAME]`: descarga la imagen si falta, ensambla el disco, bootea headless, espera al pointer helper y abre el viewer si la terminal lo soporta. `--no-view` devuelve JSON cuando el guest está listo. `--detach` regresa sin esperar.
- `start | stop | stop --force | status | ls`. `stop` apaga Android limpiamente (como hace gbos-vm al cerrar la app).
- Una VM por directorio: `~/Library/Application Support/terminal-googlebook/machines/NAME/` con `googlebook.raw`, `machine.json`, socket y token del helper, `runtime.log`. `NAME` default es `default`.
- Resolución fija por VM, default 1280x800, configurable con `--width --height --memory --cpus`. Nada de resolución nativa del host: los screenshots van al modelo y deben ser chicos y estables.
- `status` reporta: VM corriendo, helper conectado, y si el guest está en el selector de usuario (basta click en User, no hay contraseña).

### 4.2 Tools MCP (servidor stdio)

Mismo contrato que terminal-mac. Coordenadas en píxeles del guest, origen arriba a la izquierda, iguales a las del último screenshot.

| Tool | Qué hace |
| --- | --- |
| `screenshot` | PNG de la pantalla actual, devuelve ruta local |
| `click` | Click en (x, y); `--button right`, `--count 2` |
| `move` | Mueve el puntero sin click |
| `drag` | De (x1, y1) a (x2, y2) |
| `scroll` | Scroll con `dx dy` en (x, y) |
| `type` | Texto literal, UTF-8 |
| `key` | Atajo: `ctrl+t`, `enter`, `esc`, `tab`, flechas |
| `home`, `back`, `recents` | Teclas de navegación Android |
| `open_url` | Abre una URL en Chrome (equivale a un intent VIEW) |
| `status` | Estado de VM y helper |

`open_url` es la única tool que no existe en terminal-mac. Ahorra al agente diez pasos de click y type para llegar a una página, que es el caso de uso principal.

### 4.3 CLI

```bash
terminal-googlebook action NAME screenshot --output /tmp/guest.png
terminal-googlebook action NAME click 640 400
terminal-googlebook action NAME type 'hola mundo'
terminal-googlebook action NAME key ctrl+t
terminal-googlebook action NAME open_url https://example.com
terminal-googlebook mcp [NAME]          # servidor MCP stdio
terminal-googlebook mcp --config        # JSON para otros clientes MCP
terminal-googlebook view NAME           # viewer en terminal
```

Todo comando devuelve JSON y exit code distinto de cero en error.

### 4.4 Viewer en terminal

- Stream de frames solo cuando la pantalla cambia, hasta 30 fps, lz4, shared memory en Kitty y Ghostty, inline images en iTerm2. Es el viewer de terminal-mac con otra fuente de frames.
- Input: teclado, clicks, doble click, drag, scroll.
- `Ctrl+]` sale del viewer sin apagar la VM. `Ctrl+G` abre una paleta de atajos de Googlebook OS (launcher, cambio de ventana, home, back, recents, copiar, pegar).
- Terminales no soportadas reciben solo CLI y MCP; no hay ventana nativa en v1.

### 4.5 Integración con agentes

- Plugin de Claude Code con el MCP y la skill: `/plugin install terminal-googlebook --marketplace <org>/terminal-googlebook`
- `terminal-googlebook skills install` copia `skills/terminal-googlebook/SKILL.md` a `~/.claude/skills/`
- La skill enseña el loop observe → act → verify, cómo manejar el selector de usuario, y que `open_url` es el primer paso para cualquier tarea web.

## 5. Requisitos no funcionales y aislamiento

- **Latencia:** < 100 ms entre una acción MCP y el cambio visible en el siguiente screenshot. Es alcanzable porque captura e input viven en el proceso de QEMU; con ADB no lo sería.
- **Viewer:** 20 fps o más cuando la pantalla cambia, cero CPU cuando está quieta.
- **Boot:** < 60 s desde `start` hasta helper conectado (gbos-vm reporta 45 s en M5).
- **Host mínimo:** Apple Silicon, 16 GB de RAM, macOS 26 o superior, 60 GB libres. La VM usa 4 GB por default.
- **Instalación:** sin `sudo`, todo bajo `~/.local`, no toca el shell del usuario.
- **Estabilidad:** una sesión de 8 horas sin reiniciar la VM ni perder el helper.

**Modelo de aislamiento** (copiado de terminal-mac, ajustado al guest)

- Las tools solo hablan con QEMU y con el pointer helper. Nunca usan APIs de input o pantalla del host.
- El guest no ve home, proyectos, clipboard, micrófono ni cámara del host. Lo único compartido es el socket de control.
- No hay listener de red para control remoto. El helper acepta solo un host que presente el token aleatorio del boot actual.
- Red NAT por default: el guest tiene internet y puede alcanzar servicios del host o la LAN. **No es un entorno endurecido para código hostil.** `--offline` quita la red.
- Bluetooth apagado por default: el radio virtual de gbos-vm escucha en 127.0.0.1 sin contraseña.
- El guest usa KeyMint y Gatekeeper por software, no hay secure element. No sirve para cuentas o datos sensibles; trátalo como dispositivo de pruebas.
- Nada de Google se redistribuye: el instalador baja la imagen de recuperación y Cuttlefish desde servidores de Google y los verifica contra SHA-256 fijos.

## 6. Stack técnico

Decisiones cerradas. No hay "Rust o Swift": elegir dos lenguajes para la capa host significa reescribir el viewer en vez de copiarlo.

| Componente | Decisión | Por qué |
| --- | --- | --- |
| VM | Fork de gbos-vm (QEMU de UTM, virglrenderer parchado, MoltenVK, Cuttlefish) | Es lo único que bootea Googlebook OS en Mac hoy |
| Host: CLI, MCP, viewer | Swift Package, fork de terminal-mac | El viewer, el servidor MCP y el parser de input ya existen en Swift |
| Captura | Hook en el renderer de gbos-vm (CocoaSpice/virgl) que expone el framebuffer por shared memory; fallback QMP `screendump` | Frames sin permisos del guest y sin copia extra |
| Input | QMP `input-send-event` para teclado; pointer helper existente de gbos-vm para puntero absoluto | Ya funciona, mismo truco que scrcpy |
| Control QEMU | Socket QMP Unix por VM | Estándar, sin código nuevo en QEMU |
| Guest | Solo el pointer helper de gbos-vm (binario nativo, uid `shell`) | Un APK no puede inyectar input a otras apps sin permisos interactivos |
| Distribución | GitHub Release con binarios precompilados de host y guest + `get.sh` con SHA-256 | Evita Xcode, NDK y 5 min de build de Mesa al usuario final |
| Licencia | MIT; el parche de CocoaSpice queda Apache-2.0 | Igual que los dos proyectos base |

## 7. Fases

Los dos riesgos técnicos que pueden tumbar el proyecto van primero, antes de escribir una sola tool MCP. Si el spike 0 falla, la alternativa es una ventana oculta fuera de pantalla, y hay que saberlo en el día 2, no en la semana 6.

### Fase 0: spikes (1 semana)

1. **Headless.** Arrancar gbos-vm sin ventana visible y confirmar que el renderer Metal sigue produciendo frames. Resultado: un script que bootea y escribe un PNG del guest cada segundo.
2. **Input desde QMP.** Enviar `ctrl+t` y texto por `input-send-event` y mover el puntero con el helper existente, sin viewer. Resultado: Chrome abre una pestaña y recibe texto.
3. **Instalación sin build.** Empaquetar los binarios de `work/host` y `work/guest` de una máquina y confirmar que `install.sh` los acepta en otra sin NDK ni Xcode.

### Fase 1: MVP para agentes (2 a 3 semanas)

- Fork de terminal-mac: quitar Virtualization.framework, meter el runner QEMU de gbos-vm con socket QMP por VM.
- `up`, `start`, `stop`, `status`, `action`, `mcp` con `screenshot`, `click`, `type`, `key`, `open_url`, `status`.
- Resolución fija 1280x800, directorio por VM, token y socket por VM.
- Skill y plugin de Claude Code.
- Criterio de salida: el criterio de aceptación 2 pasa en un Mac limpio.

### Fase 2: viewer (1 a 2 semanas)

- Conectar la fuente de frames del host al viewer de terminal-mac.
- `move`, `drag`, `scroll`, `home`, `back`, `recents`, `Ctrl+G` con la paleta de Googlebook OS.
- Solo cuando el viewer sirva se mide fps y latencia.

### Fase 3: distribución (1 semana)

- Release firmado con binarios precompilados, `get.sh`, `doctor`.
- README, `docs/AGENT.md`, `docs/VALIDATION.md` con resultados reales en al menos dos Macs.

Lo que no está aquí (multi-VM, snapshot de accesibilidad, clipboard, ventana nativa) se decide después de que alguien use v1.

## 8. Criterios de aceptación

1. En un Mac Apple Silicon limpio con 16 GB, `curl | bash` instala sin pedir `sudo`, Xcode, NDK ni Android Studio. La primera descarga puede llegar a 9 GB.
2. `terminal-googlebook up` muestra el escritorio de Googlebook OS en Ghostty, Kitty o iTerm2 en menos de 3 minutos después de la primera descarga.
3. Claude Code, con solo el plugin instalado y sin intervención humana, ejecuta: `open_url` a una página, `screenshot`, `click` en un campo de búsqueda, `type` de un texto, `key enter`, y verifica en un segundo `screenshot` que el resultado cambió.
4. Durante todo lo anterior el puntero, el clipboard y las ventanas del host no se mueven ni cambian.
5. `stop` apaga Android limpiamente y `start` recupera el estado del disco (pestañas de Chrome abiertas incluidas).
6. El repo es MIT, público, y `docs/VALIDATION.md` registra los criterios 1 a 5 ejecutados en dos Macs distintos.

## 9. Riesgos y preguntas abiertas

| Riesgo | Impacto | Mitigación |
| --- | --- | --- |
| El renderer Metal no produce frames sin ventana | Bloquea headless | Spike 0.1. Fallback: ventana oculta fuera de pantalla, como `hide` en terminal-mac |
| El pointer helper de gbos-vm es inestable (su README lo marca experimental) | Clicks imprecisos | Modo captura de mouse QEMU como fallback para `click`; el helper solo para `move` y `drag` |
| La imagen oficial cambia de build y rompe el vendor rebuild | `up` deja de funcionar | Fijar el build (hoy 16471258) y verificar SHA-256; actualizar en releases, no al vuelo |
| terminal-mac es muy nuevo (2 estrellas, validación en vivo pendiente) | Heredar bugs de arquitectura | Validar su viewer y MCP en un Mac real antes de forkear |
| Binarios precompilados de Mesa y QEMU no corren en otros Macs o versiones de macOS | Criterio 1 falla | Build en CI por versión de macOS soportada; `doctor` detecta mismatch |

**Preguntas abiertas**

- ¿El framebuffer de gbos-vm se puede exportar por shared memory con un parche chico a CocoaSpice, o conviene QMP `screendump` a disco en v1 aunque sea más lento?
- ¿Qué atajo abre el launcher en Googlebook OS? Hay que verificarlo en el guest antes de armar la paleta de `Ctrl+G`.
- ¿`open_url` se implementa con un intent desde el helper (necesita extender el helper) o con `key` + `type` en la omnibox de Chrome (cero código en guest)? Empezar por lo segundo.

**Referencias**

- [terminal-mac](https://github.com/govijr/terminal-mac): CLI, MCP, viewer, `docs/AGENT.md`, `skills/terminal-mac/SKILL.md`
- [gbos-vm](https://github.com/skylartaylor/gbos-vm): VM, renderer, pointer helper, `run/launch.py`
- [Googlebook](https://en.wikipedia.org/wiki/Googlebook): plataforma y OS

**Instrucción para Claude Code**

Usa este PRD como especificación. Empieza por la Fase 0 y no avances a Fase 1 hasta que los tres spikes pasen. Forkea terminal-mac para la capa host y gbos-vm para la VM; no reescribas lo que ya existe en cualquiera de los dos. No uses ADB en el camino crítico. No agregues tools, flags ni abstracciones que no pidan los criterios de aceptación. Cuando dudes entre dos opciones, elige la que menos código nuevo requiera.
