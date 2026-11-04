#!/usr/bin/env python3
"""Build host/headless.m with the same sources and libraries as the viewer.
Usage: build_headless.py WORK   (output: WORK/host/headless)"""
import subprocess, sys
from pathlib import Path

work = Path(sys.argv[1]).resolve(); here = Path(__file__).resolve().parent
S = work / 'src/CocoaSpice/Sources'; fw = work / 'UTM-beta/UTM.app/Contents/Frameworks'
build = work / 'host/viewer-build'; out = work / 'host/headless'
skip = {'CSUSBDevice.m', 'CSUSBManager.m', 'CSSession+Sharing.m', 'gst_ios_init.m'}
cmd = ['clang', '-fobjc-arc', '-fblocks', '-fmodules', f'-fmodules-cache-path={build}/module-cache', '-O2', '-w']
headers = S / 'CocoaSpice/ExternalHeaders'
for p in [build / 'modules', S / 'CocoaSpice/include', S / 'CocoaSpice', S / 'CocoaSpiceRenderer/include', S / 'CocoaSpiceRenderer',
          headers, *[headers / n for n in ('glib-2.0', 'gstreamer-1.0', 'spice-1', 'spice-client-glib-2.0')]]:
    cmd += ['-I', str(p)]
cmd += [str(p) for p in sorted((S / 'CocoaSpice').glob('*.m')) if p.name not in skip] + [str(here / 'headless.m')]
for n in ('AppKit', 'Metal', 'CoreGraphics', 'CoreImage', 'IOSurface', 'CoreVideo'): cmd += ['-framework', n]
for n in ('spice-client-glib-2.0.8', 'glib-2.0.0', 'gobject-2.0.0', 'gio-2.0.0', 'gstreamer-1.0.0'):
    cmd.append(str(fw / (n + '.framework') / n))
# Second rpath: relative, so the whole work folder can be moved.
cmd += ['-Wl,-rpath,' + str(fw), '-Wl,-rpath,@executable_path/../UTM-beta/UTM.app/Contents/Frameworks', '-o', str(out)]
subprocess.run(cmd, check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(out)], check=True, capture_output=True)
print(out)
