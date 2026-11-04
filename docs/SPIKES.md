# Fase 0: estado de los spikes

La Fase 1 no empieza hasta que los tres pasen (instrucción del PRD).

| Spike | Estado | Evidencia |
| --- | --- | --- |
| 0.1 Headless | **Pasó** (M5, 16 GB, macOS 27.0.1) | Escritorio real a 1280x800 sin ventanas en el host; boot en 39 a 47 s; captura en unos 50 ms; apagado limpio en 4 s con código 0 |
| 0.2 Input | **Pasó** (misma Mac) | Puntero preciso con el helper; `ctrl+t` abre pestaña y `Hola Mundo 123` llega exacto por QMP. Ver `evidencia/spike-0.2-chrome.png` |
| 0.3 Instalación sin build | Pendiente | Solo hay una Mac: como mucho quedará parcial. El criterio 6 sigue pendiente |

## Cómo reproducir 0.1 y 0.2

```bash
cd vm && ./install.sh && cd ..           # requiere un python3 de 3.10 o más en el PATH
python3 spikes/build_headless.py vm/work
python3 spikes/spike.py boot vm/work     # imprime run_dir; frames en RUN_DIR/frames
python3 spikes/spike.py do RUN_DIR click:640:507 sleep:10 click:506:772 sleep:15 key:ctrl-t sleep:3 'type:Hola Mundo 123' sleep:3 shot:/tmp/r.png
python3 spikes/spike.py do RUN_DIR poweroff
```

## Lo aprendido que condiciona la Fase 1

- **QMP `screendump` no sirve.** Con la pantalla GL devuelve una imagen totalmente negra, y esta QEMU no trae soporte PNG. Se descarta incluso como fallback.
- **La captura va por un cliente SPICE sin ventana** (`spikes/headless.m`), que reutiliza `CSConnection` y `CSDisplay` con un renderer que no dibuja.
- **Ese cliente debe vivir tanto como la VM.** Conectado desde el arranque entrega frames; al reconectarse a una VM ya encendida devolvió capturas vacías. Hipótesis sin confirmar: el fd del scanout contiene el ID del IOSurface y la primera conexión lo consume. Por eso conviene un proceso por VM que sirva los frames a la CLI y al viewer, que así podrían entrar y salir sin reconectarse a SPICE.
- **Doble cursor.** El ratón USB inactivo deja una flecha fija junto al puntero real, y sale en las capturas que recibe el modelo.
- **Android ve una tableta.** La primera vez abre el tutorial "Try out your stylus", que roba el foco y se come las primeras teclas. Hay que cerrarlo o evitarlo.
- **Primer arranque de Chrome.** Pide "Stay signed out" y luego rechazar notificaciones. La skill debe enseñarlo.
- **Selector de usuario.** Apareció en un boot y no en otro; las acciones se pierden si no se comprueba antes.
- **`python3` de Xcode (3.9) rompe el build** porque meson 1.12.1 no se ofrece para esa versión; `prereqs.sh` no lo detecta.

## Bloqueos

El spike 0.3 y el criterio 6 piden una segunda Mac y no hay ninguna disponible.

## Diferencias entre el PRD y el código de gbos-vm

- **Transporte del helper.** No es un socket Unix: el guest se conecta por TCP a `10.0.2.2:27183` a través de la NAT, y el host escucha en `127.0.0.1`. El PRD pide que no haya listener de red para control remoto; este solo acepta conexiones de loopback y exige token.
- **`--offline`.** En `run_vm.py` elimina la NIC y con ella el helper, así que el puntero deja de funcionar. Propuesta por validar: `-netdev user,restrict=on` más `guestfwd` para conservar solo ese canal.
- **Captura.** El PRD da `screendump` como fallback, pero devuelve negro. Los frames solo salen por SPICE con GL.
- **Teclado.** La VM usa `usb-kbd`, no virtio. `input-send-event` funciona igual.
- **Herramientas de imagen.** `build-image.sh` usa `erofs-utils`, `e2fsprogs` y `lz4` de Homebrew. Como la imagen de Google no se puede redistribuir, el disco se arma en la máquina del usuario y el criterio 1 obliga a incluir esas herramientas en el paquete.
- **Clipboard.** El helper incluye sincronización de clipboard; el PRD la deja fuera de v1, así que no debe activarse.
