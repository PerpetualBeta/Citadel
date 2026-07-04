#!/usr/bin/env python3
"""Condition a music/ambient track into a seamless whole-buffer loop.

Steps:
  1. Trim leading silence (< -60 dBFS RMS, 50 ms windows).
  2. Cut the authored tail fade: keep up to the last window within 3 dB of the
     body RMS (drops fade-outs and trailing silence; keeps sustained tails).
  3. Choose the splice point by envelope correlation: search the last few
     seconds for the cut N where the outgoing tail [N-X, N) best matches the
     incoming head [0, X) — for rhythmic material this lands on the beat grid.
  4. Equal-power (sin/cos) crossfade of that tail into the head; emit y[0, N-X)
     with the blended head. The wrap is then continuous by construction.

Usage: condition.py in.wav out.wav XFADE_SECONDS SEARCH_SECONDS
"""
import numpy as np
import wave, sys

SIL_DB, BODY_DB, WIN_MS = -60.0, -3.0, 50

def load(path):
    w = wave.open(path, 'rb')
    n, sr, ch = w.getnframes(), w.getframerate(), w.getnchannels()
    x = np.frombuffer(w.readframes(n), dtype=np.int16).astype(np.float64) / 32768.0
    w.close()
    return x.reshape(-1, ch), sr

def save(path, x, sr):
    y = np.clip(x, -1, 1)
    # TPDF dither at 1 LSB before 16-bit quantise
    d = (np.random.default_rng(0).random(y.shape) + np.random.default_rng(1).random(y.shape) - 1.0) / 32768.0
    q = np.round((y + d) * 32767.0).astype(np.int16)
    w = wave.open(path, 'wb')
    w.setnchannels(x.shape[1]); w.setsampwidth(2); w.setframerate(sr)
    w.writeframes(q.tobytes()); w.close()

def envelope(x, sr):
    win = int(sr * WIN_MS / 1000)
    m = x.mean(axis=1)
    n = len(m) // win
    return np.sqrt(np.mean(m[:n*win].reshape(n, win)**2, axis=1)), win

def main(inp, outp, xfade_s, search_s):
    x, sr = load(inp)
    env, win = envelope(x, sr)
    db = 20*np.log10(np.maximum(env, 1e-10))
    body = 20*np.log10(np.sqrt(np.mean(env[len(env)//4:3*len(env)//4]**2)))

    audible = np.where(db > SIL_DB)[0]
    head = audible[0] * win                      # first audible window
    tail = (np.where(db > body + BODY_DB)[0][-1] + 1) * win   # end of body-level content
    y = x[head:tail]
    print(f"{inp}: trimmed head {head/sr:.2f}s, kept to {tail/sr:.2f}s "
          f"({len(y)/sr:.2f}s of {len(x)/sr:.2f}s)")

    X = int(xfade_s * sr)
    S = int(search_s * sr)
    eY, w2 = envelope(y, sr)
    Xw, Sw = X // w2, S // w2
    hd = eY[:Xw] - eY[:Xw].mean()
    # correlation of head window vs every candidate tail window in the search span
    best_n, best_c = len(y), -np.inf
    for nw in range(len(eY) - Sw, len(eY) + 1):
        tl = eY[nw-Xw:nw]
        tl = tl - tl.mean()
        denom = np.sqrt(np.sum(hd**2) * np.sum(tl**2))
        c = np.sum(hd * tl) / denom if denom > 0 else 0
        if c > best_c:
            best_c, best_n = c, nw * w2
    n = min(best_n, len(y))
    print(f"  splice at {n/sr:.3f}s (envelope match r={best_c:.2f}), xfade {xfade_s}s")

    t = np.linspace(0, np.pi/2, X, endpoint=False)[:, None]
    z = y[:n-X].copy()
    z[:X] = y[n-X:n] * np.cos(t) + y[:X] * np.sin(t)
    save(outp, z, sr)
    print(f"  wrote {outp}: {len(z)/sr:.3f}s ({len(z)} frames)")

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4]))
