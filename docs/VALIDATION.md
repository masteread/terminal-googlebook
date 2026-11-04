# Validación

Resultados reales. Una sola Mac hasta ahora: M5, 16 GB, macOS 27.0.1. El criterio 6 pide dos.

| Criterio | Estado | Evidencia |
| --- | --- | --- |
| 1. `curl \| bash` en un Mac limpio | Pendiente (Fase 3) | Solo existe la prueba parcial del spike 0.3 |
| 2. Escritorio en la terminal en menos de 3 min | Pendiente (Fase 2) | Sin viewer todavía |
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

## Sin probar

- Sesión de 8 horas.
- `--width`, `--height`, `--memory` y `--cpus` distintos de los valores por defecto.
- `up` cuando falta la imagen: en esta Mac la imagen ya estaba, así que la descarga automática no se ha ejercitado.
