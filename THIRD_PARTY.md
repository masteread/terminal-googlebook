# Componentes de terceros

El código de este repositorio es MIT, salvo `vm/patches/cocoaspice-viewer.patch` (Apache-2.0). El paquete del release, además, incluye estos binarios, cada uno bajo su propia licencia. Son programas separados: la licencia MIT no los cubre.

| Componente | Dónde | Licencia | Fuente |
| --- | --- | --- | --- |
| QEMU 10.0.12-utm | `bundle/host/qemu-aarch64-softmmu` | GPL-2.0 | Adjunta al release: `qemu-10.0.12-utm.tar.xz`. Solo se cambió un load command con `install_name_tool` (ver `vm/build-host.sh`) |
| erofs-utils 1.9.4 | `bundle/tools/bin` | GPL-2.0-or-later | Adjunta al release |
| e2fsprogs 1.47.4 | `bundle/tools/sbin`, `bundle/tools/lib` | GPL-2.0-or-later, LGPL, BSD-3-Clause, MIT | Adjunta al release |
| libsepol 3.11 | Enlazada en `bundle/tools/guest_graphics_memfd_policy` | LGPL-2.1-or-later | Adjunta al release; el programa está en `vm/tools-src` |
| gettext 1.0 (libintl) | `bundle/tools/lib` | LGPL-2.1-or-later | Adjunta al release |
| lz4 1.10.0 | `bundle/tools/bin`, `bundle/tools/lib` | BSD-2-Clause (biblioteca), GPL-2.0-or-later (programa) | https://github.com/lz4/lz4/tree/v1.10.0 |
| xz (liblzma) | `bundle/tools/lib` | 0BSD | https://github.com/tukaani-project/xz |
| virglrenderer (fork de UTM) | `bundle/host` | MIT | https://github.com/utmapp/virglrenderer, más `vm/patches/virglrenderer-android-interop.patch` |
| Mesa 26.2.4 | `bundle/guest` | MIT y otras permisivas | https://archive.mesa3d.org/mesa-26.2.4.tar.xz |
| CocoaSpice (fork de UTM) | `bundle/host/headless` | Apache-2.0 | https://github.com/utmapp/CocoaSpice, más `vm/patches/cocoaspice-viewer.patch` |
| Python 3.13.18 (python-build-standalone) | `bundle/python` | PSF-2.0 y otras; ver `bundle/python/lib/python3.13/LICENSE.txt` | https://github.com/astral-sh/python-build-standalone |

## Lo que no se redistribuye

Se descarga en la máquina del usuario desde su origen y se verifica contra un SHA-256 fijo: la imagen de recuperación de Googlebook y la imagen de Cuttlefish (Google), y UTM 5.0.6 con sus frameworks.
