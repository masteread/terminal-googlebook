# Validación

Resultados reales. Una sola Mac hasta ahora: M5, 16 GB, macOS 27.0.1. El criterio 6 pide dos.

| Criterio | Estado | Evidencia |
| --- | --- | --- |
| 1. `curl \| bash` en un Mac limpio | **Parcial** | Instalado con `get.sh` en un directorio vacío, con `env -i` y sin Homebrew ni SDK en el `PATH`, descarga real incluida. Misma Mac, con Xcode en disco. El zip se sirvió desde un servidor local: la URL pública de GitHub no se puede probar con el repo privado |
| 2. Escritorio en la terminal en menos de 3 min | **Parcial** | Arranque de unos 40 s y frames decodificados en una pty que se hace pasar por iTerm2 y kitty. Se probó en iTerm2 real y funciona muy bien. `up` sobre la instalación limpia, con la imagen ya armada: 49 s hasta Android listo. Falta verlo en Ghostty y Kitty de verdad |
| 3. Claude Code solo con el plugin, sin intervención | **Pasó**, en una Mac no limpia | `claude -p --plugin-dir` con solo las tools del plugin, sobre un Chrome nunca abierto: 44 s, 15 turnos, 0.67 USD. Pasó solo los diálogos de Chrome y llegó al artículo. Ver `evidencia/fase-1-agente.jpg`. Repetido en la Fase 3 con una tarea más larga (ver abajo) |
| 4. Host intacto | **Parcial** | 0 ventanas de la VM en el host y el hash del clipboard no cambió. El puntero del host no se pudo medir: la Mac estaba en uso durante la prueba. El código no llama a ninguna API de input o pantalla del host |
| 5. `stop` limpio y `start` recupera el estado | **Pasó** | Apagado en 4 s con código 0; las pestañas de Chrome siguen tras `start` |
| 6. MIT, público, dos Macs | Pendiente | Privado; sin segunda Mac |

## Fase 1: otras comprobaciones

- `up` con imagen base nueva: 42 a 44 s. `start`: 39 s (PRD: menos de 60 s).
- Acciones por CLI, incluido arrancar el proceso: `key` 91 ms, `click` 138 ms, `screenshot` 40 a 85 ms, `status` 147 ms. No mide aún el cambio visible en pantalla, que el PRD deja para la Fase 2.
- `type` con Unicode: `x mañana 日本 ¿qué? y` llega exacto.
- `--offline`: el puntero funciona, `example.com` da `ERR_NAME_NOT_RESOLVED` y un servidor real en el host da `ERR_CONNECTION_REFUSED`.
- Errores con código de salida 1: click fuera de pantalla, `file:///`, VM inexistente.
- `swift test`: 16 tests.

## Fase 2: viewer y gestos

Medido con un guest real. El viewer corrió en una pty de prueba, no en una terminal real: los fps son lo que el viewer entrega a la pty, no lo que dibuja iTerm2 o Kitty.

Después, `up` se usó en iTerm2 real y funciona muy bien. El encabezado marcó un promedio de 15 a 20 fps: **por debajo de los 20 del PRD** en esta ruta, aunque en el uso se sintió bien. Dato leído a ojo, no medido con un guion.

| Medida | Resultado | PRD |
| --- | --- | --- |
| Tool MCP hasta el primer frame distinto: `scroll` | mediana 70 ms, máx. 77 (16 muestras) | < 100 ms |
| Tool MCP hasta el primer frame distinto: `key` | mediana 65 ms, máx. 87 (16 muestras) | < 100 ms |
| fps con la página desplazándose, memoria compartida (kitty) | 24 | ≥ 20 |
| fps con la página desplazándose, PNG en línea (iTerm2) | 21 | ≥ 20 |
| CPU en reposo con viewer abierto: viewer / host / cliente SPICE | 0.65 % / 0.05 % / 0 % de un núcleo | Cero: **no literal** en el viewer |
| QEMU en reposo | 19 a 68 % de un núcleo según la medición | Sin objetivo. Sin explicar; revisar en la prueba de 8 h |

- Con la pantalla quieta solo llegan frames cuando cambia algo: 2 frames en 28 s.
- Con la paleta y los gestos desde el viewer, por secuencias de terminal reales: click (selector de usuario), doble click (abre Settings), rueda, arrastre (mueve una ventana), texto, `Ctrl+G` con launcher y Home, `Ctrl+]` deja la VM encendida. Ver `evidencia/fase-2-input-viewer.jpg`.
- Por CLI, comprobado en capturas: `scroll` en ambos sentidos, `drag`, `back`, `recents`, `home`, `move` (aparece el tooltip del dock), `key meta` (launcher), `key alt+tab` (cambia de ventana; necesita Alt pulsada 400 ms), `ctrl+a/c/v`.
- `stop` con el viewer abierto: el viewer sale y restaura la terminal.
- El puntero no aparece en los frames: el guest no lo dibuja en el scanout en modo inyección. Las capturas para agentes no lo muestran. El viewer dibuja el del agente desde la Fase 3.

## Fase 3: distribución

Paquete con firma ad-hoc, de 47 MB. Pruebas con `v0.1.0-3`.

- **Instalación limpia:** `get.sh`, `doctor` y `up --no-view` en un directorio de datos vacío. `lsof` muestra que QEMU no carga nada de Homebrew ni del árbol de compilación. La descarga de Google se cortó dos veces (`curl` 18 y 56); ahora reintenta y reanuda sola, y la segunda vez continuó desde el byte donde iba.
- **`doctor`:** antes de la descarga da `healthy: true` con `vm-files` en `pending`. Después carga QEMU de verdad: `QEMU emulator version 10.0.12`.
- **Agente en su propia máquina:** sobre esa VM recién instalada, Claude Code (Sonnet) hizo sin ayuda una tarea de cuatro pasos: Wikipedia, otra pestaña, versión de Android en Settings y volver a Chrome. 57 s, 31 turnos, 1.21 USD. Pasó solo los diálogos de Chrome sin añadir cuentas, y los datos son correctos. Ver `evidencia/fase-3-agente.jpg`.
- **Host durante esa tarea:** el hash del clipboard no cambió y la VM no abrió ventanas. La app al frente y el puntero no se pudieron usar como prueba: la Mac estaba en uso.
- **Input perdido:** en esa tarea, `type` justo después de abrir la búsqueda de Settings dejó `d ver` en vez de `Android version`. El agente lo vio en el screenshot y reintentó. La skill ya avisa de que las teclas enviadas demasiado pronto pueden perderse; no está corregido.

### Ver en vivo

Con un cliente MCP real y el viewer en una pty de iTerm2: `view` espera con la VM apagada, `start` la enciende en 39 s y responde el comando para mirar, y un segundo `start` tarda 0.1 s. El click del agente aparece en el frame, con puntero y anillo en la posición correcta, y `agent · click 640,400` en el pie. `activity` guarda `type 10 characters`, nunca el texto. Falta verlo en iTerm2 real.

**Problema abierto:** la ventana de Chrome desapareció de la pantalla en 2 de las 3 corridas de agente, una al maximizar y otra tras cargar la página, con Chrome aún activo en el dock. En la primera volvió al pulsar su icono. Causa sin investigar.

### Desviaciones del PRD

- **Tool `start` y puntero del agente:** el PRD no los pide. Se agregaron, para que un agente encienda su máquina y un dev lo vea en vivo. La tool no descarga: la primera vez pide al usuario correr `up`.
- **Release sin identidad:** el PRD pide un release firmado. Se usa firma ad-hoc y el SHA-256 de `get.sh`. Sin notarizar, macOS rechaza el zip bajado con el navegador; por eso se instala con `curl`. No se ha comprobado en una Mac que nunca lo haya visto.
- **Licencias:** el paquete incluye binarios GPL y LGPL, no solo MIT y Apache-2.0. Ver `THIRD_PARTY.md`. Sus fuentes se adjuntan al release. Es una revisión técnica, no legal: conviene una revisión legal antes de hacerlo público.

### Actualizaciones

`up` no actualiza `work/host` si ya existe: una versión futura con otros binarios de host tendrá que resolverlo.

## Sin probar

- El viewer en Ghostty y Kitty reales.
- Las acciones de paleta Back, Recents, Switch window, Copy y Paste desde el viewer; sí pasaron por CLI con los mismos comandos.

- Sesión de 8 horas: en curso.
- Una Mac sin Xcode ni herramientas de línea de comandos.
- `curl | bash` contra la URL pública de GitHub.
- `--width`, `--height`, `--memory` y `--cpus` distintos de los valores por defecto.
