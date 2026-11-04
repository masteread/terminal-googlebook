# Validación

Resultados reales. Una sola Mac hasta ahora: M5, 16 GB, macOS 27.0.1. El criterio 6 pide dos.

| Criterio | Estado | Evidencia |
| --- | --- | --- |
| 1. `curl \| bash` en un Mac limpio | Pendiente (Fase 3) | Solo existe la prueba parcial del spike 0.3 |
| 2. Escritorio en la terminal en menos de 3 min | **Parcial** | Arranque de unos 40 s y frames decodificados en una pty que se hace pasar por iTerm2 y kitty. Se probó en iTerm2 real y funciona muy bien; no se cronometró el tiempo hasta ver el escritorio. Falta verlo en Ghostty y Kitty de verdad |
| 3. Claude Code solo con el plugin, sin intervención | **Pasó**, en una Mac no limpia | `claude -p --plugin-dir` con solo las tools del plugin, sobre un Chrome nunca abierto: 44 s, 15 turnos, 0.67 USD. Pasó solo los diálogos de Chrome y llegó al artículo. Ver `evidencia/fase-1-agente.jpg` |
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

Después, `up` se usó en iTerm2 real y funciona muy bien. No quedó registrada la cifra de fps del encabezado.

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
- El puntero no aparece en los frames: el guest no lo dibuja en el scanout en modo inyección. En el viewer se usa el del terminal; las capturas para agentes no lo muestran.

## Sin probar

- El viewer en Ghostty y Kitty reales.
- La cifra de fps en iTerm2 real.
- Las acciones de paleta Back, Recents, Switch window, Copy y Paste desde el viewer; sí pasaron por CLI con los mismos comandos.

- Sesión de 8 horas.
- `--width`, `--height`, `--memory` y `--cpus` distintos de los valores por defecto.
- `up` cuando falta la imagen: en esta Mac la imagen ya estaba, así que la descarga automática no se ha ejercitado.
