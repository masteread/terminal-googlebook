#!/usr/bin/env python3
"""Spike 0.3: arma el paquete precompilado.  package.py WORK PYTHON_DIR SALIDA
Copia binarios de host y guest, y las herramientas de imagen de Homebrew con sus dylibs reubicadas.
PYTHON_DIR es un Python autónomo (python-build-standalone), porque un Mac sin Xcode no tiene python3."""
import shutil, subprocess, sys
from pathlib import Path

work, py, out = [Path(p).resolve() for p in sys.argv[1:4]]
HOMEBREW = ('/opt/homebrew/', '@@HOMEBREW')
if out.exists(): shutil.rmtree(out)
tools = out / 'tools'
for d in ('bin', 'sbin', 'lib'): (tools / d).mkdir(parents=True)

(out / 'host').mkdir()
for name in ('qemu-interop', 'qemu-aarch64-softmmu', 'libvirglrenderer.1.dylib', 'virgl_render_server', 'headless'):
    shutil.copy2(work / 'host' / name, out / 'host' / name, follow_symlinks=True)
shutil.copytree(work / 'guest', out / 'guest', symlinks=True)
shutil.copytree(work / 'tools', out / 'tools', symlinks=True, dirs_exist_ok=True, ignore=shutil.ignore_patterns('bison'))
shutil.copytree(py, out / 'python', symlinks=True)


def deps(path):
    lines = subprocess.check_output(['otool', '-L', str(path)], text=True).splitlines()[1:]
    return [l.split()[0] for l in lines]


def relocate(path, prefix):
    """Copia sus dylibs de Homebrew a tools/lib y las enlaza con rutas relativas."""
    changes = []
    for dep in deps(path):
        if not dep.startswith(HOMEBREW): continue
        name = Path(dep).name; target = tools / 'lib' / name
        if not target.exists():
            shutil.copy2(Path(dep).resolve(), target); target.chmod(0o755)
            subprocess.run(['install_name_tool', '-id', f'@loader_path/{name}', str(target)], check=True, capture_output=True)
            relocate(target, '@loader_path')
        changes += ['-change', dep, f'{prefix}/{name}']
    if changes: subprocess.run(['install_name_tool', *changes, str(path)], check=True, capture_output=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(path)], check=True, capture_output=True)


def add(source, sub):
    for item in sorted(Path(source).iterdir()):
        if not item.is_file(): continue
        if not subprocess.check_output(['file', '-b', str(item.resolve())], text=True).startswith('Mach-O'): continue
        target = tools / sub / item.name
        shutil.copy2(item.resolve(), target); target.chmod(0o755)
        relocate(target, '@loader_path/../lib')


brew = lambda f: subprocess.check_output(['/opt/homebrew/bin/brew', '--prefix', f], text=True).strip()
add(Path(brew('erofs-utils')) / 'bin', 'bin')
add(Path(brew('e2fsprogs')) / 'sbin', 'sbin')
target = tools / 'bin/lz4'; shutil.copy2(Path(brew('lz4')) / 'bin/lz4', target); target.chmod(0o755); relocate(target, '@loader_path/../lib')
left = [str(p) for p in tools.rglob('*') if p.is_file() and any(d.startswith(HOMEBREW) for d in (deps(p) if subprocess.check_output(['file', '-b', str(p)], text=True).startswith('Mach-O') else []))]
if left: sys.exit(f'quedan rutas de Homebrew: {left}')
print(out)
