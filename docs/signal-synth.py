#!/usr/bin/env python3
"""Citadel — THE SIGNAL: synthesise the intercepted first-contact transmission.

Canon: the ARC colony picked up an alien signal from the deep; it drew the swarm.
This renders that transmission from scratch (original work, like the electrical-
fault trio — no samples) as a cold, non-human beacon that grows with depth:

  • a sub-bass BREATHING drone — the dread bed you stand in;
  • an inharmonic, slowly-detuning PAD — a "wrong choir", never quite a chord;
  • the MESSAGE — metallic FM pings in a structured-but-alien data pattern, the
    same burst repeating and degrading (a weak carrier drifting in pitch/time);
  • a faint high WHINE that drifts; STATIC swelling around the bursts;
  • distant convolution SPACE (a synthetic decaying-noise IR, stereo-decorrelated)
    so it reads as coming from far below.

Two depth variants show the intended gating:
  signal-far   — the first bleed-through (faint message, drowned in reverb/static)
  signal-deep  — near the source (message forward, louder, present)

Usage:  signal-synth.py OUT_DIR
Deps:   numpy, scipy  (an isolated venv is fine; nothing here is Citadel-specific).
"""
import numpy as np, wave, sys, os
from scipy.signal import butter, filtfilt, fftconvolve

SR = 44100

def T(dur): return np.arange(int(dur * SR)) / SR

def lp(x, hz, order=4):
    b, a = butter(order, hz / (SR / 2)); return filtfilt(b, a, x)

def bp(x, lo, hi, order=2):
    b, a = butter(order, [lo / (SR / 2), hi / (SR / 2)], btype="band"); return filtfilt(b, a, x)

def slow_drift(n, rate_hz, depth, seed):
    """A slow random-walk multiplier around 1.0 (heavily low-passed noise)."""
    d = lp(np.random.default_rng(seed).standard_normal(n), rate_hz, 2)
    return 1.0 + depth * d / (np.std(d) + 1e-9)

def spectrum_burst(rng, pilot=0.26, nbits=200, bit_dur=0.0019,
                   f_pilot=808.0, f0=2050.0, f1=1024.0):
    """A ZX-Spectrum tape-load screech — the sound of raw data crossing an audio
    carrier. A steady PILOT tone (the leader buzz), then DATA: a pseudo-random
    bitstream where each bit is one short square-wave burst at one of two pulse
    frequencies (~2050 Hz vs ~1024 Hz, as the real Spectrum's 0/1 pulse widths).
    The rapid two-tone warble is the message; SQUARE waves keep it harsh + machine.
    Pitches are passed pre-drifted so each repeat degrades like a weak carrier."""
    segs = []
    if pilot > 0:
        tp = np.arange(int(pilot * SR)) / SR
        segs.append(np.sign(np.sin(2 * np.pi * f_pilot * tp)))
    nb = int(bit_dur * SR); tb = np.arange(nb) / SR
    hi = np.sign(np.sin(2 * np.pi * f0 * tb))     # a '0' pulse — the higher buzz
    lo = np.sign(np.sin(2 * np.pi * f1 * tb))     # a '1' pulse — the lower buzz
    for bit in rng.integers(0, 2, nbits):
        segs.append(lo if bit else hi)
    return np.concatenate(segs)

def add(buf, seg, start):
    i = int(start * SR); j = min(len(buf), i + len(seg))
    if i < len(buf): buf[i:j] += seg[:j - i]

def make_ir(dur, tau, lp_hz, seed):
    n = int(dur * SR)
    ir = np.random.default_rng(seed).standard_normal(n) * np.exp(-np.arange(n) / SR / tau)
    ir = lp(ir, lp_hz)
    k = int(0.004 * SR); ir[:k] *= np.linspace(0, 1, k)          # de-click the head
    return ir / (np.max(np.abs(ir)) + 1e-9)

def build(dur=24.0, msg_amp=1.0, reverb_wet=0.55, static_amp=1.0,
          ir_tau=1.1, seed=7):
    N = int(dur * SR)
    t = np.arange(N) / SR
    rng = np.random.default_rng(seed)

    # 1) SUB-BASS BREATHING DRONE — the bed. Detuned layers beat; a sub octave
    #    adds weight; a slow breath + slower swell make it feel alive/wrong.
    f0 = 43.65
    breath = 0.55 + 0.45 * np.sin(2 * np.pi * 0.07 * t - 1.4)
    swell = 0.60 + 0.40 * np.sin(2 * np.pi * 0.021 * t)
    drone = (np.sin(2 * np.pi * f0 * t)
             + 0.8 * np.sin(2 * np.pi * f0 * 1.004 * t)
             + 0.8 * np.sin(2 * np.pi * f0 * 0.996 * t)
             + 0.5 * np.sin(2 * np.pi * (f0 / 2) * t))
    # saturated body (rich harmonics) PLUS a clean sub layer so the fundamental
    # weight survives — dread from the deep wants real low-end, not just harmonics.
    sub = 0.42 * np.sin(2 * np.pi * 43.65 * t) + 0.30 * np.sin(2 * np.pi * 32.70 * t)
    drone = np.tanh(drone * 0.7) * 0.60 + sub                 # foundation — present, not dominant
    drone *= breath * swell * 0.5

    # 2) INHARMONIC "WRONG CHOIR" PAD — partials at stretched ratios, each slowly
    #    drifting in pitch + amplitude, so it never settles into a chord.
    pad = np.zeros(N)
    base = 98.0
    for k, ratio in enumerate([1.0, 1.41, 1.87, 2.53, 3.19]):
        f = base * ratio * slow_drift(N, 0.05, 0.006, seed + 10 + k)
        ph = 2 * np.pi * np.cumsum(f) / SR
        ampd = 0.5 + 0.5 * slow_drift(N, 0.03, 0.9, seed + 20 + k)
        pad += np.sin(ph) * ampd * (0.13 / (k + 1))
    pad = lp(pad, 2600) * 0.5

    # 3) THE MESSAGE — a ZX-Spectrum-style DATA transmission (see spectrum_burst):
    #    a pilot leader then a burst of square-wave data. The same signal repeats
    #    across the piece, each repeat drifting in pitch — a weak carrier degrading.
    msg = np.zeros(N)
    for b, t0 in enumerate([2.4, 9.0, 15.4, 20.8]):
        drift = 1.0 + b * 0.012 + rng.normal(0, 0.004)     # each repeat degrades sharp
        burst = spectrum_burst(rng, pilot=0.26, nbits=300 + int(rng.random() * 120),
                               bit_dur=0.0019, f_pilot=808 * drift,
                               f0=2050 * drift, f1=1024 * drift) * 0.34
        k = int(0.006 * SR); burst[:k] *= np.linspace(0, 1, k); burst[-k:] *= np.linspace(1, 0, k)
        add(msg, burst, t0)
    msg *= msg_amp

    # 4) HIGH WHINE — faint, drifting, uneasy.
    wf = 2900 * slow_drift(N, 0.08, 0.06, seed + 40)
    whine = np.sin(2 * np.pi * np.cumsum(wf) / SR) * (0.02 * (0.5 + 0.5 * np.sin(2 * np.pi * 0.13 * t)))

    # 5) STATIC — a faint continuous hiss + swells of band-noise around the bursts.
    hiss = bp(rng.standard_normal(N), 600, 4200) * 0.0045      # a thin veil, not a wash
    swellenv = lp(np.abs(msg) + 1e-6, 6.0); swellenv /= (np.max(swellenv) + 1e-9)
    carrier = bp(rng.standard_normal(N), 450, 3200) * (0.028 * swellenv)
    static = (hiss + carrier) * static_amp

    # 6) SPACE — the wet layers (message + whine + some pad) sent to a distant,
    #    stereo-decorrelated convolution reverb; the drone stays mostly dry (it's
    #    the room you're in, not the far-off source).
    wetsrc = msg + whine + 0.5 * pad
    irL = make_ir(3.0, ir_tau, 3600, seed + 50)               # dark, distant space (not airy)
    irR = make_ir(3.0, ir_tau, 3300, seed + 51)
    wetL = fftconvolve(wetsrc, irL)[:N]
    wetR = fftconvolve(wetsrc, irR)[:N]
    # normalise the wet to the dry source peak so `reverb_wet` is a true mix ratio —
    # an un-normalised convolution tail would dominate the master peak and crush the
    # drone at the final normalise (why the sub read so weak).
    wpk = max(np.max(np.abs(wetL)), np.max(np.abs(wetR))) + 1e-9
    src_pk = np.max(np.abs(wetsrc)) + 1e-9
    wetL *= src_pk / wpk; wetR *= src_pk / wpk

    dry = drone + 0.7 * pad + msg + whine + static
    L = dry + reverb_wet * wetL
    R = dry + reverb_wet * wetR

    # master: DC-block, soft-clip, normalise, fades
    def master(x):
        x = filtfilt(*butter(2, 20 / (SR / 2), btype="high"), x)
        x = np.tanh(x * 1.1)
        x = filtfilt(*butter(4, 8800 / (SR / 2)), x)          # roll off the airy hiss — a dark transmission
        x /= (np.max(np.abs(x)) + 1e-9); x *= 0.92
        fi, fo = int(1.6 * SR), int(2.8 * SR)
        x[:fi] *= np.linspace(0, 1, fi); x[-fo:] *= np.linspace(1, 0, fo)
        return x
    return np.stack([master(L), master(R)], axis=1)


def write_wav(path, stereo):
    data = (np.clip(stereo, -1, 1) * 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(data.tobytes())
    print("wrote", path)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Desktop")
    os.makedirs(out, exist_ok=True)
    # the first bleed-through: message faint + distant, drowned in dark space
    write_wav(os.path.join(out, "citadel-signal-far.wav"),
              build(msg_amp=0.75, reverb_wet=0.85, static_amp=0.9, ir_tau=1.6, seed=7))
    # near the source: message forward, present, louder
    write_wav(os.path.join(out, "citadel-signal-deep.wav"),
              build(msg_amp=1.5, reverb_wet=0.5, static_amp=0.6, ir_tau=1.0, seed=7))
