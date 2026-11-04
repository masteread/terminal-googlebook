# Fase 0: resultado de los spikes

El PRD pedía los tres aprobados antes de la Fase 1. Se avanzó con el 0.3 parcial, al no haber segunda Mac.

| Spike | Estado | Evidencia |
| --- | --- | --- |
| 0.1 Headless | **Pasó** (M5, 16 GB, macOS 27.0.1) | Escritorio real a 1280x800 sin ventanas en el host; boot en 39 a 47 s; captura en unos 50 ms; apagado limpio en 4 s con código 0 |
| 0.2 Input | **Pasó** (misma Mac) | Puntero preciso con el helper; `ctrl+t` abre pestaña y `Hola Mundo 123` llega exacto por QMP. Ver `evidencia/spike-0.2-chrome.png` |
| 0.3 Instalación sin build | **Parcial** (una sola Mac) | Paquete de 43 MB instalado con `env -i`, sin Homebrew, NDK ni SDK en el `PATH`; la VM arrancó en 46 s desde esa instalación, sin bibliotecas de Homebrew ni del build original. Falta probarlo en otra Mac |

## Lo aprendido, y cómo quedó en la Fase 1

- **QMP `screendump` no sirve.** Con la pantalla GL devuelve negro, y esta QEMU no trae soporte PNG. Se descarta incluso como fallback.
- **La captura va por un cliente SPICE sin ventana** (`vm/host/headless.m`), conectado desde el arranque y durante toda la vida de la VM. Al reconectarse a una VM encendida devolvió capturas vacías. Hipótesis sin confirmar: el fd del scanout contiene el ID del IOSurface y la primera conexión lo consume.
- **Puntero por inyección y sin ratón USB.** La tableta virtual abría el tutorial "Try out your stylus" y el ratón inactivo dibujaba un segundo cursor. Con `G 0 0` y `--no-mouse` no aparece ninguno de los dos, y las capturas no muestran cursor.
- **`open_url` usa un intent, no el omnibox.** Era la pregunta abierta del PRD. Se probó primero la vía sin código en el guest y falló: el click en el dock minimiza Chrome si ya está al frente y el texto salió corrupto (`ttps://www.wikipedia.orgh`). `VM_OPEN_URL` usa el canal de verbos ya existente, sin extender el helper.
- **Selector de usuario.** `VM_STATUS` da `user=0` en el selector y `user=10` en el escritorio. Aparece a partir del segundo arranque.
- **Foco.** Tras `ctrl+t` el omnibox no siempre recibe el teclado; con click o `ctrl+l` sí. La skill lo enseña.
- **`--offline`.** `restrict=on` más un `guestfwd` solo para el helper. Verificado: el puntero funciona, sin internet y sin acceso a un servidor real en el host.
- **Ruido conocido.** `init` aborta y se reinicia con frecuencia dentro del guest (`crash_dump helper failed`), en todos los arranques desde el primero. Hay que vigilarlo en la prueba de 8 horas.

## Alcance del spike 0.3

Se probó en esta misma Mac: `scripts/package_vm.py` arma el paquete y `vm/install.sh` lo acepta con `GBOS_BUNDLE`. Reutilizó las descargas ya hechas, sin repetirlas.

Sin probar, porque requiere otra máquina: otro chip u otra versión de macOS, un Mac que nunca tuvo Xcode, y un `/usr/bin` sin las herramientas de línea de comandos. `/opt/homebrew` seguía en disco; se comprobó con `otool` y `lsof` que no se usa.

El paquete incluye un Python autónomo (python-build-standalone) porque los scripts de imagen lo necesitan y un Mac sin Xcode no trae `python3`. Sus licencias quedaron en `THIRD_PARTY.md`.

## Bloqueos

El spike 0.3 no puede cerrarse del todo y el criterio 6 sigue pendiente: piden una segunda Mac y no hay ninguna disponible.

## Diferencias entre el PRD y el código de gbos-vm

- **Transporte del helper.** No es un socket Unix: el guest se conecta por TCP a `10.0.2.2:27183` a través de la NAT, y el host escucha en `127.0.0.1`. El PRD pide que no haya listener de red para control remoto; este solo acepta conexiones de loopback y exige token. Como el puerto es fijo en el guest, solo puede correr una VM a la vez, igual que pide el alcance de v1.
- **Captura.** El PRD da `screendump` como fallback, pero devuelve negro. Los frames solo salen por SPICE con GL.
- **Teclado.** La VM usa `usb-kbd`, no virtio. `input-send-event` funciona igual.
- **Herramientas de imagen.** `build-image.sh` usa `erofs-utils`, `e2fsprogs` y `lz4` de Homebrew. Como la imagen de Google no se puede redistribuir, el disco se arma en la máquina del usuario y el criterio 1 obliga a incluir esas herramientas en el paquete.
- **Clipboard.** El clipboard del host nunca interviene y lo que el guest envía se descarta. Pero `type` usa el clipboard del guest para el texto sin tecla directa (`ñ`, `日本`), porque un teclado virtual no puede producirlo. Android muestra unos segundos su preview abajo a la izquierda.
