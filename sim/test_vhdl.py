#!/usr/bin/env python3
"""Checks the codec interface (sim/tb_codec.vhd) and the register bank (sim/tb_regs.vhd), then that
every effect's VHDL (and the cabinet's) computes exactly what sim/fx_model.py computes.

    python3 sim/test_vhdl.py                  # everything
    python3 sim/test_vhdl.py chorus flanger   # just these effects

Simulates each effect with GHDL (sim/tb_fx.vhd) at a few knob settings over the start of the riff
and compares the output sample by sample. Uses a local `ghdl` if there is one, otherwise the
ghdl/ghdl Docker image.
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

import fx_model as m

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'sim' / 'out' / 'ghdl'
SRC = ['codec.vhd', 'sim/tb_codec.vhd', 'pedal_regs.vhd', 'sim/tb_regs.vhd', 'sat_pkg.vhd', 'booster.vhd', 'drive.vhd', 'tremolo.vhd', 'delay.vhd', 'wah.vhd', 'phaser.vhd',
       'reverb.vhd', 'compressor.vhd', 'moddelay.vhd', 'cab.vhd', 'sim/tb_fx.vhd']
IMAGE = 'ghdl/ghdl:6.0.0-mcode-ubuntu-24.04'
N = 24000                                   # 0.5 s: past the shortest delay and every reverb line
KNOBS = [(0, 31), (16, 16), (31, 0)]

if shutil.which('ghdl'):
    GHDL = ['ghdl']
else:
    GHDL = ['docker', 'run', '--rm', '-u', str(os.getuid()), '-v', f'{ROOT}:{ROOT}', '-w', str(OUT),
            IMAGE, 'ghdl']


def ghdl(cmd, *args):
    subprocess.run(GHDL + [cmd, '--std=93c', *args], cwd=OUT, check=True)


def model(fx, x, a, b):
    if fx == 15:
        return m.cab(x, CAB_COEFS)
    if fx == 0:
        g = a * 32 + b
        return [m.sat16((v * g) >> 8) for v in x]
    return {1: lambda: m.drive(x, a, b, m.DIST), 2: lambda: m.drive(x, a, b, m.OD), 3: lambda: m.tremolo(x, a, b),
            4: lambda: m.delay(x, a, b), 5: lambda: m.wah(x, a, b), 6: lambda: m.phaser(x, a, b),
            7: lambda: m.reverb(x, a, b), 8: lambda: m.compressor(x, a, b),
            9: lambda: m.moddelay(x, a, b, m.CHORUS), 10: lambda: m.moddelay(x, a, b, m.FLANGER)}[fx]()


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'work-obj93.cf').unlink(missing_ok=True)   # start from a clean work library
    sig = m.riff()
    m.calibrate(sig)
    global CAB_COEFS
    CAB_COEFS = m.cab_coefs(sig)
    x = sig[:N]
    (OUT / 'in.txt').write_text('\n'.join(map(str, x)) + '\n')
    ghdl('-a', *[str(ROOT / f) for f in SRC])
    ghdl('-e', 'tb_fx')
    only = sys.argv[1:]                     # e.g. test_vhdl.py chorus flanger: just those effects
    if not only:
        ghdl('-e', 'tb_codec')
        ghdl('-r', 'tb_codec')              # these two stop with an error on the first wrong value
        ghdl('-e', 'tb_regs')
        ghdl('-r', 'tb_regs')

    names = {0: 'booster', 1: 'distortion', 2: 'overdrive', 3: 'tremolo', 4: 'delay', 5: 'wah', 6: 'phaser',
             7: 'reverb', 8: 'compressor', 9: 'chorus', 10: 'flanger', 15: 'cab'}
    bad = 0
    for fx, name in names.items():
        if only and name not in only:
            continue
        for a, b in (KNOBS if name != 'cab' else [(0, 0)]):   # the cab has no knobs
            ghdl('-r', 'tb_fx', '--ieee-asserts=disable-at-0', f'-gFX={fx}', f'-gA={a}', f'-gB={b}', '-gIN_FILE=in.txt', '-gOUT_FILE=out.txt')
            got = [int(v) for v in (OUT / 'out.txt').read_text().split()]
            want = model(fx, x, a, b)
            diff = [i for i in range(N) if got[i] != want[i]]
            status = 'ok' if not diff else f'MISMATCH at {len(diff)} samples, first n={diff[0]}: vhdl {got[diff[0]]} model {want[diff[0]]}'
            print(f'{name:10s} A={a:2d} B={b:2d}  {status}')
            bad += bool(diff)
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
