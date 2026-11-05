# Third-party components

The code in this repository is MIT, except `vm/patches/cocoaspice-viewer.patch` (Apache-2.0). The release package also includes these binaries, each under its own license. They are separate programs, and the MIT license doesn't cover them.

| Component | Where | License | Source |
| --- | --- | --- | --- |
| QEMU 10.0.12-utm | `bundle/host/qemu-aarch64-softmmu` | GPL-2.0 | Attached to the release: `qemu-10.0.12-utm.tar.xz`. Only a load command was changed, with `install_name_tool` (see `vm/build-host.sh`) |
| erofs-utils 1.9.4 | `bundle/tools/bin` | GPL-2.0-or-later | Attached to the release |
| e2fsprogs 1.47.4 | `bundle/tools/sbin`, `bundle/tools/lib` | GPL-2.0-or-later, LGPL, BSD-3-Clause, MIT | Attached to the release |
| libsepol 3.11 | Linked into `bundle/tools/guest_graphics_memfd_policy` | LGPL-2.1-or-later | Attached to the release; the program is in `vm/tools-src` |
| gettext 1.0 (libintl) | `bundle/tools/lib` | LGPL-2.1-or-later | Attached to the release |
| lz4 1.10.0 | `bundle/tools/bin`, `bundle/tools/lib` | BSD-2-Clause (library), GPL-2.0-or-later (program) | https://github.com/lz4/lz4/tree/v1.10.0 |
| xz (liblzma) | `bundle/tools/lib` | 0BSD | https://github.com/tukaani-project/xz |
| virglrenderer (UTM fork) | `bundle/host` | MIT | https://github.com/utmapp/virglrenderer, plus `vm/patches/virglrenderer-android-interop.patch` |
| Mesa 26.2.4 | `bundle/guest` | MIT and other permissive licenses | https://archive.mesa3d.org/mesa-26.2.4.tar.xz |
| CocoaSpice (UTM fork) | `bundle/host/headless` | Apache-2.0 | https://github.com/utmapp/CocoaSpice, plus `vm/patches/cocoaspice-viewer.patch` |
| Python 3.13.18 (python-build-standalone) | `bundle/python` | PSF-2.0 and others; see `bundle/python/lib/python3.13/LICENSE.txt` | https://github.com/astral-sh/python-build-standalone |

## Not redistributed

These are downloaded on the user's machine from their source and verified against a fixed SHA-256: the Googlebook recovery image and the Cuttlefish image (Google), and UTM 5.0.6 with its frameworks.
