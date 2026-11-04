#!/usr/bin/env python3
"""Spikes 0.1 y 0.2 del PRD: VM sin ventana, frames por SPICE (headless.m), teclado por QMP y helper de puntero.

  spike.py boot WORK [WxH]         arranca headless, espera el boot e imprime RUN_DIR
  spike.py do RUN_DIR PASO...      ejecuta pasos en orden:
      shot:ARCHIVO.png             copia el último frame del cliente headless (uno por segundo)
      key:ctrl-t                   teclas QMP simultáneas (qcodes separados por -)
      type:TEXTO                   texto ASCII por QMP
      click:X:Y                    click con el pointer helper
      sleep:SEGUNDOS
      poweroff                     apaga Android por el canal de control
Solo biblioteca estándar. Sin ADB. WORK es la carpeta de build de gbos-vm (vm/work).
"""
import datetime, json, os, shutil, socket, subprocess, sys, time
from pathlib import Path

RUN = Path(__file__).resolve().parent.parent / 'vm/run'
sys.path.insert(0, str(RUN))
import vm_control

HELPER_PORT = 27183
SHIFTED = dict(zip('!@#$%^&*()', '1234567890'))
SHIFTED.update({'_': 'minus', '+': 'equal', '{': 'bracket_left', '}': 'bracket_right', '|': 'backslash',
                ':': 'semicolon', '"': 'apostrophe', '<': 'comma', '>': 'dot', '?': 'slash', '~': 'grave_accent'})
PLAIN = {' ': 'spc', '-': 'minus', '=': 'equal', '[': 'bracket_left', ']': 'bracket_right', '\\': 'backslash',
         ';': 'semicolon', "'": 'apostrophe', ',': 'comma', '.': 'dot', '/': 'slash', '`': 'grave_accent', '\n': 'ret'}


def qcodes(ch):
    """(qcode, requiere shift) de un carácter ASCII."""
    if ch.islower() or ch.isdigit(): return ch, False
    if ch.isupper(): return ch.lower(), True
    if ch in PLAIN: return PLAIN[ch], False
    if ch in SHIFTED: return SHIFTED[ch], True
    raise ValueError(f'carácter sin qcode: {ch!r}')


class QMP:
    def __init__(self, run_dir):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.connect(str(Path(run_dir) / 'qmp.sock'))
        self.file = self.sock.makefile('r')
        json.loads(self.file.readline())  # saludo
        self.cmd('qmp_capabilities')

    def cmd(self, name, **arguments):
        msg = {'execute': name}
        if arguments: msg['arguments'] = arguments
        self.sock.sendall((json.dumps(msg) + '\n').encode())
        while True:
            line = self.file.readline()
            if not line: raise ConnectionError('QMP cerró la conexión')
            reply = json.loads(line)
            if 'event' in reply: continue
            if 'error' in reply: raise RuntimeError(f'{name}: {reply["error"]}')
            return reply['return']

    def keys(self, names, down):
        events = [{'type': 'key', 'data': {'down': down, 'key': {'type': 'qcode', 'data': k}}} for k in names]
        self.cmd('input-send-event', events=events)

    def combo(self, names):
        self.keys(names, True); time.sleep(.03); self.keys(list(reversed(names)), False); time.sleep(.03)

    def text(self, text):
        for ch in text:
            code, shift = qcodes(ch)
            self.combo(['shift', code] if shift else [code])


class Helper:
    """Lado host del pointer helper de gbos-vm: el guest se conecta a 127.0.0.1:27183 por la NAT."""
    def __init__(self, run_dir, width, height, timeout=30):
        listener = socket.socket(); listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(('127.0.0.1', HELPER_PORT)); listener.listen(1); listener.settimeout(timeout)
        self.conn, _ = listener.accept(); listener.close()
        self.conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.send('A ' + (Path(run_dir) / 'token').read_text().strip())
        self.send(f'G {width} {height}')
        time.sleep(1)  # el guest registra su tableta virtual

    def send(self, line): self.conn.sendall((line + '\n').encode())

    def click(self, x, y):
        self.send(f'M {x} {y}'); time.sleep(.05); self.send('D 1'); time.sleep(.05); self.send('U 1')


def boot(work, display='1280x800'):
    work = Path(work).resolve()
    name = 'spike-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    run_dir = work / 'logs' / name
    log = (work / 'spike-boot.log').open('ab')
    t0 = time.monotonic()
    vm = subprocess.Popen([sys.executable, str(RUN / 'run_vm.py'), str(work), name, '--seconds', '86400', '--display', display,
                           '--no-audio', '--no-bluetooth'], stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    # El cliente se conecta desde el arranque y no se reconecta: ver docs/SPIKES.md.
    sock = run_dir / 'spice.sock'
    while not sock.exists():
        if vm.poll() is not None or time.monotonic() - t0 > 30: sys.exit(f'la VM no arrancó; revisa {run_dir}')
        time.sleep(.1)
    fw = work / 'UTM-beta/UTM.app/Contents/Frameworks'
    subprocess.Popen([str(work / 'host/headless'), str(sock), str(run_dir / 'frames'), '3600'],
                     env=dict(os.environ, DYLD_FRAMEWORK_PATH=str(fw), VM_MOUSE_SEAMLESS='0'), stdout=(run_dir / 'headless.log').open('wb'),
                     stderr=subprocess.STDOUT, start_new_session=True)
    serial = run_dir / 'serial.log'
    while time.monotonic() - t0 < 300:
        if vm.poll() is not None: sys.exit(f'la VM terminó con código {vm.returncode}; revisa {run_dir}')
        if serial.exists() and b'VM_BOOT_COMPLETED' in serial.read_bytes():
            print(json.dumps({'run_dir': str(run_dir), 'boot_seconds': round(time.monotonic() - t0, 1)}))
            time.sleep(8)  # igual que launch.py antes de ajustar la densidad
            vm_control.send(run_dir, f'VM_DENSITY {round(240 * int(display.split("x")[0]) / 1920)}')
            return
        time.sleep(.5)
    sys.exit(f'sin VM_BOOT_COMPLETED en 300 s; revisa {serial}')


def latest_frame(run_dir):
    frames = sorted((Path(run_dir) / 'frames').glob('frame-*.png'))
    if not frames: sys.exit('el cliente headless aún no ha escrito ningún frame')
    return frames[-1]


def do(run_dir, steps):
    command = json.loads((Path(run_dir) / 'command.json').read_text())['command']
    width = next(a.split('=')[1] for a in command if '.xres=' in a)
    height = next(a.split('=')[1] for a in command if '.yres=' in a)
    qmp, helper = QMP(run_dir), None
    for step in steps:
        kind, _, rest = step.partition(':'); t = time.monotonic()
        if kind == 'shot': shutil.copyfile(latest_frame(run_dir), rest)
        elif kind == 'key': qmp.combo(rest.split('-'))
        elif kind == 'type': qmp.text(rest)
        elif kind == 'click':
            helper = helper or Helper(run_dir, width, height)
            x, y = rest.split(':'); helper.click(int(x), int(y))
        elif kind == 'sleep': time.sleep(float(rest))
        elif kind == 'poweroff': vm_control.send(run_dir, 'VM_POWEROFF')
        else: sys.exit(f'paso desconocido: {step}')
        print(json.dumps({'step': step, 'ms': round((time.monotonic() - t) * 1000)}), flush=True)


if __name__ == '__main__':
    if len(sys.argv) >= 3 and sys.argv[1] == 'boot': boot(*sys.argv[2:4])
    elif len(sys.argv) >= 4 and sys.argv[1] == 'do': do(sys.argv[2], sys.argv[3:])
    else: sys.exit(__doc__)
