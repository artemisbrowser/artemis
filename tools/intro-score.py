#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

"""Composes the onboarding intro's score from synthesis alone.
  tools/intro-score.py [out.m4a] [--wav out.wav]
Needs numpy and scipy. The beats must match IntroBeat in Artemis/views/onboarding/IntroScore.swift."""
import os
import subprocess
import sys
import tempfile
import wave

import numpy as np
import scipy.signal as sig
from scipy.ndimage import minimum_filter1d, uniform_filter1d

RATE = 48_000
BAR = 2.2  # 109 bpm; the chords change every two bars
PINGS = (8 * BAR, 9 * BAR, 10 * BAR)  # the left arm appears, the right arm, the swoosh
REVEAL = 10 * BAR  # the one climax: the comet's pass
SHRINK = 12 * BAR
FINAL = SHRINK + BAR / 2  # the card lands, the pad keys off, the motif's last note rings
ECHO = 0.75 * BAR / 4  # a dotted eighth
LENGTH = FINAL + 5.0
N = int(RATE * LENGTH)
T = np.arange(N) / RATE

rng = np.random.default_rng(1969)
HIT_LUFS = -12.0  # the loudest 3 s window
CEILING_DB = -1.5  # true peak, leaving the AAC encoder room


def hz(m):
    return 440.0 * 2 ** ((m - 69) / 12)


def ease(a, b, t):
    x = np.clip((np.asarray(t) - a) / (b - a), 0, 1)
    return x * x * (3 - 2 * x)


def at(t):
    return int(round(t * RATE))


def filt(kind, f, x, order=2):
    return sig.sosfilt(sig.butter(order, f, kind, fs=RATE, output="sos"), x, axis=-1)


def pan(mono, p):
    """constant power, p in -1...1 (scalar or per sample)"""
    angle = (np.asarray(p) + 1) * np.pi / 4
    return np.stack([mono * np.cos(angle), mono * np.sin(angle)])


def noise(n, pink=False):
    x = rng.standard_normal(n)
    if not pink:
        return x
    spectrum = np.fft.rfft(x)
    spectrum[1:] /= np.sqrt(np.arange(1, len(spectrum)))
    y = np.fft.irfft(spectrum, n)
    return y / y.std()


def swept(x, centre, kind="bandpass", width=0.5, block=512):
    """a 2nd-order filter whose cutoff follows `centre`, in Hz per sample"""
    out = np.empty_like(x)
    zi = None
    for i in range(0, len(x), block):
        f = float(np.clip(centre[min(i + block // 2, len(centre) - 1)], 30, 16_000))
        band = [f * (1 - width / 2), f * (1 + width / 2)] if kind == "bandpass" else f
        sos = sig.butter(2, band, kind, fs=RATE, output="sos")
        if zi is None:
            zi = np.zeros((len(sos), 2))
        out[i : i + block], zi = sig.sosfilt(sos, x[i : i + block], zi=zi)
    return out


def room(rt, seconds, predelay=0.04):
    """a stereo impulse response: early reflections, then a diffuse tail whose highs die first;
    rt is the RT60 below 250 Hz, to 1 kHz, to 4 kHz and above"""
    n = at(seconds)
    t = np.arange(n) / RATE
    bands = [("lowpass", 250), ("bandpass", [250, 1000]), ("bandpass", [1000, 4000]), ("highpass", 4000)]
    ir = np.zeros((2, n))
    for ch in range(2):
        src = noise(n)
        ir[ch] = sum(filt(kind, f, src, 4) * np.exp(-6.91 * t / r) for (kind, f), r in zip(bands, rt))
        ir[ch] *= ease(predelay, predelay + 0.02, t)
        for _ in range(12):
            ir[ch, at(rng.uniform(0.01, 0.08))] += rng.choice([-1, 1]) * rng.uniform(4, 10)
    ir = filt("lowpass", 11_000, ir)
    return ir / np.sqrt((ir**2).sum() / 2)


HALL = room((5.0, 4.0, 2.0, 1.2), 6.0)
CLOUD = room((9.0, 8.0, 4.5, 2.5), 10.0, predelay=0.06)


# --- voices -------------------------------------------------------------------------


def saws(f, n, voices=5, cents=18):
    """detuned saws spread across the field, each drifting slowly in pitch"""
    t = np.arange(n) / RATE
    out = np.zeros((2, n))
    for v in range(voices):
        drift = 1 + 0.002 * np.sin(2 * np.pi * rng.uniform(0.1, 0.3) * t + rng.uniform(0, 6))
        x = sig.sawtooth(2 * np.pi * np.cumsum(f * 2 ** (rng.uniform(-cents, cents) / 1200) * drift) / RATE + rng.uniform(0, 6))
        out += pan(x, 1.8 * v / (voices - 1) - 0.9)
    return out / np.sqrt(voices)


def chord(notes, dur, attack=1.5, release=2.5):
    n = at(dur + release)
    t = np.arange(n) / RATE
    out = sum(saws(hz(m), n) for m in notes) / np.sqrt(len(notes))
    return out * ease(0, attack, t) * np.exp(-np.maximum(0, t - dur) / (release / 4))


def sub(f, dur, attack=1.5, release=1.0):
    n = at(dur + release)
    t = np.arange(n) / RATE
    x = np.sin(2 * np.pi * f * t) + 0.15 * np.sin(4 * np.pi * f * t)
    return x * ease(0, attack, t) * np.exp(-np.maximum(0, t - dur) / (release / 4))


def pluck(f, bright, decay=0.35):
    """a saw-like pluck whose upper harmonics die first; `bright` 0 to 1"""
    n = at(decay * 4)
    t = np.arange(n) / RATE
    out = np.zeros(n)
    for k in range(1, int(min(24, 8000 / f)) + 1):
        rate = (1 + (k - 1) * (0.6 * (1 - bright) + 0.08)) / decay
        out += k ** -(1 + 1.2 * (1 - bright)) * np.sin(2 * np.pi * k * f * t + rng.uniform(0, 6)) * np.exp(-rate * t)
    return out * np.minimum(1, t / 0.003)


def chime(f, decay=3.0, index=1.2, p=0.0):
    """a glassy FM tone, its two sides a few cents apart, placed at p in -1...1"""
    n = at(decay * 4)
    t = np.arange(n) / RATE
    out = []
    for cents in (-4, 4):
        g = f * 2 ** (cents / 1200)
        mod = np.exp(-t / 0.4) * (index * np.sin(2 * np.pi * 2 * g * t) + 0.35 * index * np.sin(2 * np.pi * 3.5 * g * t))
        out.append(np.sin(2 * np.pi * g * t + mod) * np.exp(-t / decay) * np.minimum(1, t / 0.004))
    angle = (p + 1) * np.pi / 4
    return np.stack(out) * np.array([[np.cos(angle)], [np.sin(angle)]]) * np.sqrt(2)


def chorus(x, base=0.012, depth=0.003, rate=0.35):
    i = np.arange(x.shape[1])
    out = np.empty_like(x)
    for c, phase in ((0, 0.0), (1, np.pi)):
        d = (base + depth * np.sin(2 * np.pi * rate * i / RATE + phase)) * RATE
        out[c] = x[c] + np.interp(i - d, i, x[c])
    return out / np.sqrt(2)


def pingpong(x, delay, feedback, repeats=6):
    """echoes of the mono sum, alternating sides, each darker than the last"""
    out = x.copy()
    echo = x.mean(axis=0)
    for k in range(1, repeats + 1):
        echo = filt("lowpass", 5000, echo) * feedback
        shift = at(delay * k)
        out[k % 2, shift:] += echo[: x.shape[1] - shift]
    return out


# --- the score ----------------------------------------------------------------------------

mix = np.zeros((3, 2, N))  # dry, hall, cloud


def add(sound, start, gain, hall=0.0, cloud=0.0):
    stereo = sound if sound.ndim == 2 else pan(sound, 0)
    i = at(start)
    j = min(N, i + stereo.shape[1])
    for bus, level in enumerate((1.0, hall, cloud)):
        if level:
            mix[bus, :, i:j] += stereo[:, : j - i] * gain * level


def place(bus, sound, start, gain):
    i = at(start)
    j = min(N, i + sound.shape[1])
    bus[:, i:j] += sound[:, : j - i] * gain


# D maj9, B m11, E m9, G maj9#11 over a D pedal, two bars each; D6/9 at the climax
CHORDS = [(2, [50, 57, 61, 64, 66]), (4, [47, 54, 57, 62, 64]), (6, [52, 59, 62, 66, 67]), (8, [55, 62, 66, 69, 73]), (10, [50, 57, 62, 64, 66, 71])]
ROOTS = [38, 35, 40, 31, 38]
MOTIF = [81, 88, 95]

# the pad: a D drone from the start, the chords crossfading, one low-pass opening across the whole build
pads = np.zeros((2, N))
place(pads, chord([50, 57], FINAL, attack=3.0, release=0.4), 0, 1.0)
for k, (bar, notes) in enumerate(CHORDS):
    start = bar * BAR - (1.2 if bar == 10 else 0.4)
    end = FINAL if bar == 10 else CHORDS[k + 1][0] * BAR + 0.3
    place(pads, chord(notes, end - start, attack=1.6 if bar == 10 else 1.5, release=0.4 if bar == 10 else 2.5), start, 0.7 + 0.1 * k)
cut = 220 * (5000 / 220) ** (np.clip(T / REVEAL, 0, 1) ** 1.4)
pads = np.stack([swept(c, cut, "lowpass") + 0.5 * swept(c, cut, "bandpass", width=0.35) for c in pads])
add(chorus(pads) * (0.25 + 0.75 * ease(0, REVEAL, T) ** 1.2), 0, 0.1, hall=0.6, cloud=0.12)

# the sub under each chord, swelling into the climax
subs = np.zeros((2, N))
place(subs, pan(sub(hz(38), 2 * BAR, attack=2.5), 0), 0, 1.0)
for k, ((bar, _), root) in enumerate(zip(CHORDS, ROOTS)):
    start = bar * BAR - 0.3
    end = FINAL if bar == 10 else CHORDS[k + 1][0] * BAR + 0.2
    place(subs, pan(sub(hz(root), end - start, attack=0.8, release=0.4 if bar == 10 else 0.8), 0), start, 1.0)
add(subs * (0.35 + 0.65 * ease(2, REVEAL, T)), 0, 0.12)

# the air: the chords' top notes two octaves up, heard only through the long room, growing from the third chord
for k, (bar, notes) in enumerate(CHORDS[2:], 2):
    start = bar * BAR - 0.5
    end = FINAL if bar == 10 else CHORDS[k + 1][0] * BAR + 0.5
    air = chord([m + 24 for m in notes[-2:]], end - start, attack=2.0, release=0.4 if bar == 10 else 2.0)
    add(np.stack([filt("lowpass", 6000, c) for c in air]), start, 0.012 * (k - 1), cloud=1.0)

# the motif: three glass notes, one as each arm appears and the last on the swoosh
for when, m, p, gain in zip(PINGS, MOTIF, (-0.5, 0.5, 0.0), (0.1, 0.11, 0.06)):
    add(pingpong(chime(hz(m), decay=2.2, p=p), ECHO, 0.4), when, gain, hall=0.4, cloud=0.8)

# each arm's flight away from the viewer: noise darkening as it recedes towards its side
for when, side in zip(PINGS[:2], (-1, 1)):
    fly = np.arange(at(1.8)) / RATE
    gone = np.clip(fly / 1.1, 0, 1)
    swoosh = swept(noise(len(fly), pink=True), 2500 * (300 / 2500) ** gone, "bandpass", 0.8)
    add(pan(swoosh * np.minimum(1, fly / 0.04) * np.exp(-fly / 0.4), side * (0.2 + 0.5 * gone)), when, 0.05, hall=0.4, cloud=0.3)

# the arpeggio: eighths from the comet's first light, sixteenths from the first arm, opening and rising with the pad
arp = np.zeros((2, N))
SHAPE = [0, 2, 4, 1, 3, 5, 2, 4]
when, k = 4 * BAR, 0
while when < SHRINK - 0.01:
    notes = next(n for b, n in reversed(CHORDS) if when >= b * BAR - 0.01)
    tones = sorted(notes[1:]) + [notes[1] + 12, notes[2] + 12]
    rise = ease(4 * BAR, REVEAL, when)
    place(arp, pan(pluck(hz(tones[SHAPE[k % 8]]), 0.1 + 0.8 * rise), 0.25 * np.sin(k * 1.3)), when, (0.35 + 0.65 * rise) * (1.0 if k % 4 == 0 else 0.8))
    when += BAR / 8 if when < PINGS[0] - 0.01 else BAR / 16
    k += 1
duck = 1 - 0.55 * sum(np.exp(-np.maximum(0, T - p) / 0.3) * (T >= p) for p in PINGS)
add(pingpong(arp, ECHO, 0.45) * duck, 0, 0.045, hall=0.4, cloud=0.25)

# the build's breath: noise rising from the fourth chord into the climax
BREATH = 7 * BAR
rise_t = np.arange(at(REVEAL + 4 - BREATH)) / RATE
span = REVEAL - BREATH
centre = 300 * (5000 / 300) ** np.clip(rise_t / span, 0, 1)
riser = np.stack([swept(noise(len(rise_t), pink=True), centre, "bandpass", 0.6) for _ in range(2)])
add(riser * np.clip(rise_t / span, 0, 1) ** 2 * np.exp(-np.maximum(0, rise_t - span) / 1.2), BREATH, 0.04, hall=0.5, cloud=0.5)

# the comet's pass: a run of glass notes up the climax chord, left to right
for k, m in enumerate([74, 76, 78, 81, 83, 86, 88, 90, 93, 95]):
    add(chime(hz(m), decay=0.8, index=0.8, p=-0.7 + 1.4 * k / 9), REVEAL - 0.15 + 0.07 * k, 0.018, hall=0.4, cloud=0.6)

# the landing: the motif again as the window shrinks, its last note on the card as the pad keys off
for when, m, p in zip((SHRINK, SHRINK + 0.55, FINAL), MOTIF, (-0.4, 0.1, 0.4)):
    add(pingpong(chime(hz(m), decay=1.2, p=p), ECHO, 0.45), when, 0.03, hall=0.5, cloud=0.4)
land = np.arange(at(4.0)) / RATE
add((np.sin(2 * np.pi * hz(38) * land) + 0.4 * np.sin(2 * np.pi * hz(50) * land)) * np.exp(-land / 1.0) * np.minimum(1, land / 0.02), FINAL, 0.06, hall=0.3)


# --- the rooms and the master -------------------------------------------------------------


def k_weighted(x):
    """BS.1770's pre-filter and RLB weighting at 48 kHz"""
    y = sig.lfilter([1.53512485958697, -2.69169618940638, 1.19839281085285], [1, -1.69065929318241, 0.73248077421585], x, axis=1)
    return sig.lfilter([1, -2, 1], [1, -1.99004745483398, 0.99007225036621], y, axis=1)


def loudness(x, window):
    """loudness in LUFS of each `window`-second stretch, every 100 ms"""
    power = uniform_filter1d((k_weighted(x) ** 2).sum(axis=0), at(window), mode="constant")
    return -0.691 + 10 * np.log10(power[:: at(0.1)] + 1e-12)


def integrated(x):
    blocks = 10 ** ((loudness(x, 0.4) + 0.691) / 10)
    blocks = blocks[-0.691 + 10 * np.log10(blocks) > -70]
    gate = -0.691 + 10 * np.log10(blocks.mean()) - 10
    return -0.691 + 10 * np.log10(blocks[-0.691 + 10 * np.log10(blocks) > gate].mean())


def true_peak(x):
    return np.abs(sig.resample_poly(x, 4, 1, axis=1)).max(axis=0).reshape(-1, 4).max(axis=1)


def limit(x, ceiling, look=0.005, release=0.15):
    """a look-ahead brickwall on 4x-oversampled peaks, recovering exponentially"""
    need = minimum_filter1d(np.minimum(1, ceiling / np.maximum(true_peak(x), 1e-9)), 2 * at(look) + 1)
    fall = np.exp(-1 / (release * RATE))
    gain = need.copy()
    for i in np.flatnonzero(need < 1)[:1]:
        for j in range(i, len(gain)):
            gain[j] = min(need[j], 1 - (1 - gain[j - 1]) * fall)
    return x * uniform_filter1d(gain, at(look))


for bus, ir in ((1, HALL), (2, CLOUD)):
    mix[0] += np.stack([sig.fftconvolve(mix[bus, c], ir[c])[:N] for c in range(2)]) * 0.5
out = mix[0]
del mix

out = filt("highpass", 35, out, 4)
mid, side = (out[0] + out[1]) / 2, filt("highpass", 150, (out[0] - out[1]) / 2)
out = np.stack([mid + side, mid - side])
closing = 16_000 * (6000 / 16_000) ** ease(SHRINK - 0.1, SHRINK + 1.2, T)
out = np.stack([swept(c, closing, "lowpass") for c in out])

ceiling = 10 ** (CEILING_DB / 20)
for _ in range(3):
    out *= 10 ** ((HIT_LUFS - loudness(out, 3.0).max()) / 20)
    out = limit(np.tanh(out * 1.1) / 1.1, ceiling * 0.98)
m = loudness(out, 0.4)
print(f"integrated {integrated(out):.1f} LUFS, loudest 3 s {loudness(out, 3.0).max():.1f}, true peak {20 * np.log10(true_peak(out).max()):.2f} dBTP")
print("momentary " + " ".join(f"{s}s:{m[min(len(m) - 1, int(s * 10) + 2)]:.0f}" for s in (1, 3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 22, 23, 25, 26.4, 27.5, 28.5, 29.5, 30.5, 31.5, 32.3)))

args = sys.argv[1:]
wav_out = args[args.index("--wav") + 1] if "--wav" in args else None
target = next((a for a in args if a.endswith(".m4a")), os.path.join(os.path.dirname(__file__), "../Artemis/views/onboarding/intro-score.m4a"))
with tempfile.TemporaryDirectory() as tmp:
    path = wav_out or os.path.join(tmp, "score.wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((np.clip(out.T, -1, 1) * 32767).astype("<i2").tobytes())
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "192000", "-q", "127", path, target], check=True)
print(target)
