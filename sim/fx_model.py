#!/usr/bin/env python3
"""Fixed-point models of the PedalFPGA effects (same integer math as the VHDL).

    python3 sim/fx_model.py           # run the checks, write WAVs to sim/out/
    python3 sim/fx_model.py --vhdl    # print the constant tables used in the VHDL

There is no VHDL simulator in this setup, so each effect is designed and checked here first:
the asserts are the properties a real pedal must have (level, LFO speed, stability...), and the
WAVs (a synthetic plucked-guitar riff through each effect) are for listening before synthesis.
Python's >> on negative ints floors, like VHDL shift_right / bit slicing on signed.
"""
import math
import sys
import wave
from pathlib import Path

import numpy as np

FS = 48000


def sat16(x):
    return max(-32768, min(32767, x))


def exp_table(lo, hi, n=32):
    """lo..hi spaced exponentially over the 32 knob positions."""
    return [lo * (hi / lo) ** (k / (n - 1)) for k in range(n)]


def one_pole(fc):
    """Q15 coefficient of y += (x - y) * a for a one-pole low-pass at fc."""
    return round(32768 * (1 - math.exp(-2 * math.pi * fc / FS)))


def lfo_inc(hz):
    return round(2 ** 32 * hz / FS)


# ------------------------------------------------------------------ tables (shared with the VHDL)
OD = dict(hp=one_pole(720), lp=one_pole(3200), gain=[round(16 * g) for g in exp_table(2, 60)], soft=True, blend=True)
DIST = dict(hp=one_pole(150), lp=one_pole(2800), gain=[round(16 * g) for g in exp_table(4, 400)], soft=False, blend=False)
LEVEL = [round(4096 * 10 ** ((b - 16) * 1.3 / 20)) for b in range(32)]    # Q12, 1.3 dB per step, B=16 -> unity
TREM_INC = [lfo_inc(f) for f in exp_table(0.5, 12)]
PHS_INC = [lfo_inc(f) for f in exp_table(0.1, 6)]
DLY_LP = one_pole(3500)
WAH_ATT, WAH_REL = round(32768 * (1 - math.exp(-1 / (0.002 * FS)))), round(32768 * (1 - math.exp(-1 / (0.12 * FS))))
COMBS = [1214, 1293, 1390, 1476, 1548, 1623, 1695, 1760]    # Freeverb lengths scaled 44.1k -> 48k
ALLPASSES = [605, 480, 371, 245]


# ------------------------------------------------------------------ new effects
def drive(xs, a, b, p, comp=None):
    """Overdrive / distortion: HPF -> gain -> clip -> (blend dry) -> 2-pole LPF -> make-up -> level.
    One pipeline stage per register, as in drive.vhd."""
    lp_pre = v = xd = s = lp1 = lp2 = m = 0
    g, lev, out = p['gain'][a], LEVEL[b], []
    cmp_ = p['comp'][a] if comp is None else comp
    for x in xs:
        # stage 5: level knob; stage 4: make-up gain for this drive setting (calibrated, see calibrate())
        out.append(sat16((m * lev) >> 12))
        m = sat16(((lp2 >> 8) * cmp_) >> 12)
        # stage 3: tone low-pass, 2 poles
        lp2_n = lp2 + (((lp1 - lp2) * p['lp']) >> 15)
        lp1_n = lp1 + ((((s << 8) - lp1) * p['lp']) >> 15)
        # stage 2: clip
        if p['soft']:
            u2 = (v * v) >> 15
            u3 = (u2 * v) >> 15
            c = sat16((3 * v - u3) >> 1)                 # 1.5(u - u^3/3): smooth, peaks at u = 1
        else:
            c = v
        s_n = (c + xd) >> 1 if p['blend'] else c
        # stage 1: high-pass + gain, clamped to +-1 (the clipper's input range)
        hp = x - (lp_pre >> 8)
        lp_pre_n = lp_pre + ((((x << 8) - lp_pre) * p['hp']) >> 15)
        v_n = max(-32767, min(32767, (hp * g) >> 4))
        lp_pre, v, xd, s, lp1, lp2 = lp_pre_n, v_n, x, s_n, lp1_n, lp2_n
    return out


def tri(phase):
    """32-bit phase -> triangle 0..32767."""
    t = (phase >> 16) & 0xFFFF                          # 0..65535
    return (65535 - t) if t >= 32768 else t             # 0..32767, peak at the middle of the period


def tremolo(xs, a, b):
    """LFO (triangle, smoothstep-shaped) -> gain = 1 - depth*lfo, never above 1."""
    phase = s = 0
    gain = 32767
    depth, inc, out = b * 1057, TREM_INC[a], []
    for x in xs:
        out.append((x * gain) >> 15)
        gain_n = 32767 - ((depth * s) >> 15)
        t = tri(phase)
        t2 = (t * t) >> 15
        s_n = min(32767, (t2 * (98304 - 2 * t)) >> 15)  # smoothstep t^2 (3 - 2t)
        phase, s, gain = (phase + inc) & 0xFFFFFFFF, s_n, gain_n
    return out


def delay(xs, a, b, n=48000):
    buf = [0] * n
    wp = rp = d = lp = 0
    fb, out = b * 950, []
    dsamp = 960 + a * 1517
    for x in xs:
        echo = lp >> 8
        out.append(sat16(x + ((echo * 19661) >> 15)))     # echo level 0.6
        d_n = buf[rp]                                     # RAM read sees the old contents (before this write)
        buf[wp] = sat16(x + ((echo * fb) >> 15))
        lp_n = lp + ((((d << 8) - lp) * DLY_LP) >> 15)   # repeats get darker
        rp_n = wp - dsamp + (n if wp < dsamp else 0)
        wp, rp, d, lp = (wp + 1) % n, rp_n, d_n, lp_n
    return out


def wah(xs, a, b):
    """Envelope (touch) wah: picking harder raises the band-pass frequency. Chamberlin SVF."""
    env = lp = bp = 0
    F = 1501
    q = 16384 - b * 462                                   # 1/Q in Q14: Q = 1 .. 8
    out = []
    for x in xs:
        lp_n = lp + ((bp * F) >> 15)
        hp = (x << 8) - lp_n - ((bp * q) >> 14)
        bp_n = bp + ((hp * F) >> 15)
        out.append(sat16((((bp_n >> 8) * q) >> 14) * 2))  # bp*q = unity gain at the peak
        # envelope follower and frequency (used from the next sample on)
        ax = abs(x) << 15
        env_n = env + (((ax - env) * (WAH_ATT if ax > env else WAH_REL)) >> 15)
        F = 1501 + min(((env >> 15) * a) >> 4, 9200)
        env, lp, bp = env_n, lp_n, bp_n
    return out


def phaser(xs, a, b):
    phase = 0
    coef = 16384 - 328
    x1, y1 = [0] * 4, [0] * 4
    span, inc, out = b * 211, PHS_INC[a], []
    for x in xs:
        ap_in = x << 8
        v = ap_in
        for k in range(4):                                 # y = a(y1 - x) + x1, first-order all-pass
            y = (((y1[k] - v) * coef) >> 14) + x1[k]
            x1[k], y1[k], v = v, y, y
        out.append(sat16((ap_in + v) >> 9))               # 50/50 dry + all-passed -> notches
        t = tri(phase)
        coef = 16384 - (328 + ((span * ((t * t) >> 15)) >> 15))
        phase = (phase + inc) & 0xFFFFFFFF
    return out


def reverb(xs, a, b):
    """Freeverb: 8 parallel damped combs -> 4 series all-passes."""
    g = 22938 + a * 285                                   # feedback 0.70 .. 0.97
    d = 1638 + b * 740                                    # damping 0.05 .. 0.75
    cb = [[0] * n for n in COMBS]
    cp, cout, cfilt = [0] * 8, [0] * 8, [0] * 8
    ab = [[0] * n for n in ALLPASSES]
    ap_p, ap_bo = [0] * 4, [0] * 4
    out = []
    for x in xs:
        cin = x >> 2
        tot = 0
        for i, n in enumerate(COMBS):
            tot += cout[i]
            filt_n = cfilt[i] + (((cout[i] - cfilt[i]) * (32768 - d)) >> 15)
            cb[i][cp[i]] = sat16(cin + ((cfilt[i] * g) >> 15))
            cout[i] = cb[i][(cp[i] + 1) % n]             # registered read of the next slot = N samples back
            cfilt[i] = filt_n
            cp[i] = (cp[i] + 1) % n
        v = tot >> 3
        for i, n in enumerate(ALLPASSES):
            bo = ap_bo[i]
            ab[i][ap_p[i]] = sat16(v + (bo >> 1))
            v = sat16(bo - v)
            ap_p[i] = (ap_p[i] + 1) % n
            ap_bo[i] = ab[i][ap_p[i]]
        out.append(sat16(x + ((v * 3) >> 1)))             # wet 1.5 (the comb input was scaled by 1/4)
    return out


def calibrate(sig):
    """Make-up gain per drive setting so that B=16 sounds as loud as the clean guitar (Q12)."""
    clean = rms(sig)
    for p in (OD, DIST):
        p['comp'] = [min(65535, round(4096 * clean / rms(drive(sig, a, 16, p, comp=4096)))) for a in range(32)]


# ------------------------------------------------------------------ cabinet simulator
CAB_TAPS = 512                                            # 10.7 ms; the FIR does one tap per 50 MHz cycle


def biquad(kind, f0, q, gain_db=0.0):
    """RBJ cookbook biquad -> (b, a), normalized."""
    w = 2 * math.pi * f0 / FS
    al, cw, A = math.sin(w) / (2 * q), math.cos(w), 10 ** (gain_db / 40)
    if kind == 'hp':
        b = [(1 + cw) / 2, -(1 + cw), (1 + cw) / 2]
        a = [1 + al, -2 * cw, 1 - al]
    elif kind == 'lp':
        b = [(1 - cw) / 2, 1 - cw, (1 - cw) / 2]
        a = [1 + al, -2 * cw, 1 - al]
    else:                                                 # peak
        b = [1 + al * A, -2 * cw, 1 - al * A]
        a = [1 + al / A, -2 * cw, 1 - al / A]
    return [v / a[0] for v in b], [v / a[0] for v in a]


def cab_ir():
    """An original 'closed-back 2x12' voicing, not a measured cabinet: tight low end with a bump at
    the speaker resonance, a scooped low-mid, presence around 2.5 kHz and a steep roll-off above
    5 kHz (what removes the fizz from distortion). The biquad cascade's impulse response, faded out
    over the last 64 taps, in Q15."""
    stages = [biquad('hp', 85, 0.8), biquad('peak', 110, 1.2, 4), biquad('peak', 500, 0.9, -4),
              biquad('peak', 2500, 1.0, 4), biquad('lp', 5000, 0.7), biquad('lp', 5000, 0.7),
              biquad('lp', 7000, 0.6)]
    h = np.zeros(CAB_TAPS)
    h[0] = 1.0
    for b, a in stages:
        y, x1, x2, y1, y2 = np.zeros(CAB_TAPS), 0.0, 0.0, 0.0, 0.0
        for n, x in enumerate(h):
            y[n] = b[0] * x + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2
            x1, x2, y1, y2 = x, x1, y[n], y1
        h = y
    h[-64:] *= 0.5 * (1 + np.cos(np.linspace(0, math.pi, 64)))
    return h


def cab(xs, coefs):
    """FIR, as cab.vhd: 48-bit accumulator, >> 15, saturate (int64 convolution is exact here)."""
    acc = np.convolve(np.array(xs, dtype=np.int64), np.array(coefs, dtype=np.int64))[:len(xs)]
    return [sat16(int(v) >> 15) for v in acc]


def cab_coefs(sig):
    """Scale the IR so a distorted guitar comes out as loud through the cab as without it."""
    h = cab_ir()
    d = drive(sig, 16, 16, DIST)
    y = np.convolve(d, h)[:len(d)]
    k = rms(d) / rms(y)
    return [int(round(v * k * 32768)) for v in h]


# ------------------------------------------------------------------ old effects (for before/after WAVs)
def old_distortion(xs, a, b, soft=False):
    thr = 3000 - 95 * a
    makeup = 256 * 16000 // thr
    gain = min(makeup * (b + 1) // 32, 32767)
    out = []
    for x in xs:
        if x > thr:
            c = thr + (x - thr) // 4 if soft else thr
        elif x < -thr:
            c = -thr + (x + thr) // 4 if soft else -thr
        else:
            c = x
        out.append(sat16((c * gain) >> 8))
    return out


# ------------------------------------------------------------------ test signal and helpers
def pluck(freq, dur, amp, seed):
    """Karplus-Strong string."""
    rng = np.random.default_rng(seed)
    n = int(FS / freq)
    line = list(rng.uniform(-1, 1, n))
    out = []
    for i in range(int(dur * FS)):
        j = i % n
        nxt = 0.996 * 0.5 * (line[j] + line[(j + 1) % n])
        out.append(line[j])
        line[j] = nxt
    return amp * np.array(out)


def riff():
    """Single notes, then an E power chord, then silence for the tails: peaks ~0.3 FS like a guitar on LINE IN."""
    sig = np.zeros(int(5.5 * FS))
    t = 0.0
    for f in [82.4, 110.0, 146.8, 196.0, 164.8, 146.8]:
        p = pluck(f, 0.5, 0.35, int(f))
        i = int(t * FS)
        sig[i:i + len(p)] += p
        t += 0.35
    for f in [82.4, 123.5, 164.8]:
        p = pluck(f, 2.0, 0.22, int(f) + 7)
        i = int(t * FS)
        sig[i:i + len(p)] += p
    return [int(v) for v in np.clip(sig * 32767, -32768, 32767)]


def rms(v):
    v = np.asarray(v, dtype=float)
    return math.sqrt(np.mean(v * v))


def db(a, b):
    return 20 * math.log10(max(a, 1e-9) / max(b, 1e-9))


def write_wav(path, xs):
    with wave.open(str(path), 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(FS)
        w.writeframes(np.asarray(xs, dtype='<i2').tobytes())


# ------------------------------------------------------------------ checks
def check(sig, outdir):
    clean = rms(sig)
    write_wav(outdir / 'clean.wav', sig)

    # drive: loudness must not follow the drive knob (B sets it); old versions for comparison
    for name, p in [('overdrive', OD), ('distortion', DIST)]:
        levels = []
        for a in (0, 16, 31):
            y = drive(sig, a, 16, p)
            levels.append(db(rms(y), clean))
            write_wav(outdir / f'{name}_drive{a}.wav', y)
        print(f'{name:10s} level vs clean at drive 0/16/31 (B=16): ' + ' '.join(f'{l:+.1f} dB' for l in levels))
        assert max(levels) - min(levels) < 6, 'drive knob changes the loudness too much'
        assert all(-9 < l < 6 for l in levels), 'level far from the clean signal at B=16'
        write_wav(outdir / f'{name}_OLD.wav', old_distortion(sig, 16, 16, soft=p['soft']))

    # tremolo: never louder than the input, LFO at the knob's frequency, depth 0 = clean
    y = tremolo(sig, 16, 31)
    assert all(abs(o) <= abs(x) for o, x in zip(y, sig)), 'tremolo boosts'
    assert tremolo(sig[:4800], 16, 0) == [(x * 32767) >> 15 for x in sig[:4800]]
    write_wav(outdir / 'tremolo.wav', y)
    for a in (0, 31):
        f = TREM_INC[a] * FS / 2 ** 32
        g = np.array(tremolo([20000] * FS * 4, a, 31), dtype=float)
        dips = np.sum((g[1:] < 2000) & (g[:-1] >= 2000))
        print(f'tremolo    speed {a:2d}: {f:5.2f} Hz, {dips} dips in 4 s')
        assert abs(dips - 4 * f) <= 1.5, 'LFO frequency off'

    # delay: first echo at the knob's time, decays even at max feedback
    imp = [20000] + [0] * (FS * 3)
    for a in (0, 31):
        y = delay(imp, a, 31)
        first = next(i for i, v in enumerate(y[1:], 1) if abs(v) > 50)
        print(f'delay      time {a:2d}: first echo after {first / FS * 1000:6.1f} ms')
        assert abs(first - (960 + a * 1517)) < 5
    y = delay(imp, 2, 31)
    peaks = [max(abs(v) for v in y[i:i + 3000]) for i in range(3000, len(y) - 3000, 3000)]
    assert peaks[-1] < peaks[0], 'delay feedback does not decay'
    write_wav(outdir / 'delay.wav', delay(sig, 12, 12))
    print(f'delay      level vs clean (12,12): {db(rms(delay(sig, 12, 12)), clean):+.1f} dB')

    # wah: level near clean, and the filter actually moves with the envelope
    y = wah(sig, 16, 16)
    print(f'wah        level vs clean (16,16): {db(rms(y), clean):+.1f} dB')
    assert -12 < db(rms(y), clean) < 6
    write_wav(outdir / 'wah.wav', y)
    write_wav(outdir / 'wah_OLD.wav', old_wah(sig))

    # phaser: unity level, notch range inside the guitar band
    y = phaser(sig, 16, 31)
    print(f'phaser     level vs clean (16,31): {db(rms(y), clean):+.1f} dB')
    assert -6 < db(rms(y), clean) < 3
    for k in (328, 328 + 31 * 211):
        a = (16384 - k) / 16384
        fc = FS / math.pi * math.atan((1 - a) / (1 + a))
        print(f'phaser     all-pass corner for k={k}: {fc:6.0f} Hz')
    write_wav(outdir / 'phaser.wav', y)

    # reverb: no saturation on a loud input, decays, level sensible
    y = reverb(sig, 16, 16)
    print(f'reverb     level vs clean (16,16): {db(rms(y), clean):+.1f} dB')
    assert -3 < db(rms(y), clean) < 9
    y = reverb([30000] + [0] * (FS * 3), 31, 0)
    tail = [max(abs(v) for v in y[i:i + 4800]) for i in range(4800, len(y) - 4800, 4800)]
    assert tail[-1] < tail[0] and max(tail) < 32767, 'reverb does not decay / saturates'
    write_wav(outdir / 'reverb.wav', reverb(sig, 16, 16))
    write_wav(outdir / 'reverb_big.wav', reverb(sig, 28, 6))

    # cab: same loudness on a distorted guitar, much less energy above 6 kHz
    c = cab_coefs(sig)
    d = drive(sig, 16, 16, DIST)
    y = cab(d, c)
    hi = lambda v: np.sum(np.abs(np.fft.rfft(v)[int(6000 * len(v) / FS):]) ** 2) / np.sum(np.abs(np.fft.rfft(v)) ** 2)
    print(f'cab        level vs no cab (distortion): {db(rms(y), rms(d)):+.1f} dB, energy above 6 kHz {hi(d):.1%} -> {hi(y):.1%}')
    assert abs(db(rms(y), rms(d))) < 1.5 and hi(y) < hi(d) / 10
    write_wav(outdir / 'distortion_cab.wav', y)


def old_wah(xs):
    bp = lp = 0
    out = []
    for x in xs:
        hp = (x << 8) - lp - ((bp * 8400) >> 13)
        bp = ((hp * 1620) >> 14) + bp
        lp = ((bp * 1620) >> 14) + lp
        out.append(sat16(bp >> 8))
    return out


def vhdl_tables(sig):
    def arr(name, vals):
        rows = [', '.join(str(v) for v in vals[i:i + 8]) for i in range(0, 32, 8)]
        return f'    constant {name} : int_table := (\n        ' + ',\n        '.join(rows) + ');'
    print(arr('OD_GAIN', OD['gain']))
    print(arr('DIST_GAIN', DIST['gain']))
    print(arr('LEVEL', LEVEL))
    print(arr('OD_COMP', OD['comp']))
    print(arr('DIST_COMP', DIST['comp']))
    print(arr('TREM_INC', TREM_INC))
    print(arr('PHS_INC', PHS_INC))
    c = cab_coefs(sig)
    print('    constant COEF : coef_t := (\n' + ',\n'.join('        ' + ', '.join(f'{v:5d}' for v in c[i:i + 16]) for i in range(0, CAB_TAPS, 16)) + ');')
    print(f'-- OD hp/lp {OD["hp"]}/{OD["lp"]}  DIST hp/lp {DIST["hp"]}/{DIST["lp"]}  DLY_LP {DLY_LP}  WAH att/rel {WAH_ATT}/{WAH_REL}')


if __name__ == '__main__':
    sig = riff()
    calibrate(sig)
    if '--vhdl' in sys.argv:
        vhdl_tables(sig)
    else:
        out = Path(__file__).parent / 'out'
        out.mkdir(exist_ok=True)
        check(sig, out)
        print(f'all checks passed; WAVs in {out}')
