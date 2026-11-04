# Fase 0: estado de los spikes

La Fase 1 no empieza hasta que los tres pasen (instrucción del PRD).

| Spike | Estado | Evidencia |
| --- | --- | --- |
| 0.1 Headless | No ejecutado | `spikes/spike.py` solo se probó contra un QMP y un guest simulados |
| 0.2 Input por QMP y helper | No ejecutado | Igual que 0.1 |
| 0.3 Instalación sin build | No ejecutado | Requiere un build y una segunda máquina |

## Bloqueos

1. Homebrew no está instalado y su instalador pide contraseña de administrador.
2. El Android SDK requiere aceptar las licencias de Google con `sdkmanager`.
3. El spike 0.3 y el criterio 6 necesitan una segunda Mac.

## Cómo correrlos

```bash
cd vm && ./install.sh && cd ..
python3 spikes/spike.py boot vm/work                     # imprime run_dir
python3 spikes/spike.py do RUN_DIR watch:30:/tmp/frames  # 0.1
python3 spikes/spike.py do RUN_DIR click:X:Y sleep:2 key:ctrl-t type:hola shot:/tmp/r.png  # 0.2
python3 spikes/spike.py do RUN_DIR poweroff
```

Si el selector de usuario aparece, primero hay que hacer click en **User**, con las coordenadas de una captura.

## Diferencias entre el PRD y el código de gbos-vm

- **Transporte del helper.** No es un socket Unix: el guest se conecta por TCP a `10.0.2.2:27183` a través de la NAT, y el host escucha en `127.0.0.1`. El PRD pide que no haya listener de red para control remoto; este solo acepta conexiones de loopback y exige token.
- **`--offline`.** En `run_vm.py` elimina la NIC y con ella el helper, así que el puntero deja de funcionar. Propuesta por validar: `-netdev user,restrict=on` más `guestfwd` para conservar solo ese canal.
- **Captura.** QEMU corre con `-display none` y los frames salen por SPICE con GL. Sin probarlo no se sabe si `screendump` devuelve imagen, ni si el guest renderiza sin un cliente SPICE conectado. Si falla, el siguiente intento es un cliente CocoaSpice sin ventana.
- **Teclado.** La VM usa `usb-kbd`, no virtio. `input-send-event` debería funcionar igual; falta confirmarlo.
- **Herramientas de imagen.** `build-image.sh` usa `erofs-utils`, `e2fsprogs` y `lz4` de Homebrew. Como la imagen de Google no se puede redistribuir, el disco se arma en la máquina del usuario y el criterio 1 obliga a incluir esas herramientas en el paquete.
- **Clipboard.** El helper incluye sincronización de clipboard; el PRD la deja fuera de v1, así que no debe activarse.
