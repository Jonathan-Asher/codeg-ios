#!/usr/bin/env python3
"""Synthesise Codeg's bundled notification tones.

Each tone is built here from sine partials and filtered noise, so there is
nothing to license: chime, ping, glass, bell, pop, two-tone, marimba and
knock, 0.3 to 1.5 s each, with soft attacks and decays. The script writes a
16-bit mono WAV per tone with Python's `wave` module and converts it with
macOS `afconvert` to the Core Audio file iOS plays for a push
(`aps.sound`): linear PCM, 22.05 kHz, so each file stays small.

    scripts/make-notification-sounds.py [--out CodegiOS/Resources/Sounds]

The output is deterministic (the noise and the dither use fixed seeds), so
running it again reproduces the committed files.
"""

import argparse
import math
import random
import shutil
import struct
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

RATE = 22050
TAU = 2 * math.pi
# Loudness the tones are matched to (the loudest 50 ms, see `loudness`), and
# the peak none may pass.
TARGET_LOUDNESS = 0.21
MAX_PEAK = 0.9


def silence(seconds):
    return [0.0] * int(round(seconds * RATE))


def add(into, sound, at=0.0):
    """Mix `sound` into `into`, starting `at` seconds in (grows as needed)."""
    start = int(round(at * RATE))
    end = start + len(sound)
    if end > len(into):
        into.extend([0.0] * (end - len(into)))
    for i, value in enumerate(sound):
        into[start + i] += value
    return into


def envelope(i, attack, tau):
    """A raised-cosine attack of `attack` seconds, then an exponential decay
    with time constant `tau` seconds."""
    t = i / RATE
    if t < attack:
        return 0.5 - 0.5 * math.cos(math.pi * t / attack)
    return math.exp(-(t - attack) / tau)


def note(freq, seconds, partials, attack=0.004, glide=0.0, phase_seed=0):
    """A struck note: `partials` are (frequency ratio, amplitude, decay tau,
    detune in Hz). `glide` bends the pitch by that fraction over the first
    40 ms (a ping's settle)."""
    rng = random.Random(phase_seed)
    phases = [rng.random() * TAU for _ in partials]
    count = int(round(seconds * RATE))
    out = [0.0] * count
    for (ratio, amp, tau, detune), phase in zip(partials, phases):
        acc = phase
        for i in range(count):
            t = i / RATE
            bend = 1.0 + glide * math.exp(-t / 0.04)
            acc += TAU * (freq * ratio * bend + detune) / RATE
            out[i] += amp * envelope(i, attack, tau) * math.sin(acc)
    return out


def sweep(f0, f1, sweep_seconds, seconds, attack, tau):
    """A sine whose pitch moves from f0 to f1 (exponentially) over
    `sweep_seconds`: a bubble."""
    count = int(round(seconds * RATE))
    out = [0.0] * count
    acc = 0.0
    for i in range(count):
        t = i / RATE
        k = min(t / sweep_seconds, 1.0)
        freq = f0 * (f1 / f0) ** k
        acc += TAU * freq / RATE
        out[i] = envelope(i, attack, tau) * math.sin(acc)
    return out


def bandpassed_noise(seconds, center, q, attack, tau, seed):
    """White noise through a two-pole band-pass (RBJ cookbook), with an
    envelope: the click of a knuckle on wood."""
    rng = random.Random(seed)
    w0 = TAU * center / RATE
    alpha = math.sin(w0) / (2 * q)
    b0, b1, b2 = alpha, 0.0, -alpha
    a0, a1, a2 = 1 + alpha, -2 * math.cos(w0), 1 - alpha
    count = int(round(seconds * RATE))
    out = [0.0] * count
    x1 = x2 = y1 = y2 = 0.0
    for i in range(count):
        x0 = rng.uniform(-1.0, 1.0) * envelope(i, attack, tau)
        y0 = (b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
        out[i] = y0
        x2, x1, y2, y1 = x1, x0, y1, y0
    return out


# ── The tones ──


def chime():
    """Two soft bell notes a fourth apart, G5 then C6, ringing together."""
    partials = [(1.0, 1.0, 0.55, 0.0), (2.0, 0.22, 0.28, 0.0), (3.0, 0.07, 0.16, 0.0),
                (4.07, 0.05, 0.10, 0.0)]
    out = silence(1.3)
    add(out, note(783.99, 1.16, partials, phase_seed=1), 0.0)
    add(out, note(1046.50, 1.16, partials, phase_seed=2), 0.14)
    return out


def ping():
    """One short, clear A6 that settles onto its pitch."""
    partials = [(1.0, 1.0, 0.09, 0.0), (2.0, 0.18, 0.05, 0.0), (3.0, 0.05, 0.03, 0.0)]
    return note(1760.0, 0.4, partials, attack=0.002, glide=0.012, phase_seed=3)


def glass():
    """A tapped glass: B6 with a glass's stretched overtones and a slow
    shimmer from two strings of partials a hair apart."""
    partials = [(1.0, 0.55, 0.50, 0.0), (1.0, 0.45, 0.50, 1.6), (2.76, 0.22, 0.20, 0.0),
                (2.76, 0.15, 0.20, 2.2), (5.40, 0.06, 0.08, 0.0)]
    return note(1975.53, 1.2, partials, attack=0.003, phase_seed=4)


def bell():
    """A small church bell on C5: hum, prime, minor-third tierce, quint and
    nominal, the low ones ringing longest."""
    partials = [(0.5, 0.35, 0.70, 0.0), (1.0, 1.0, 0.50, 0.0), (1.2, 0.45, 0.40, 0.0),
                (1.5, 0.30, 0.30, 0.0), (2.0, 0.40, 0.25, 0.0), (2.5, 0.12, 0.15, 0.0),
                (3.0, 0.10, 0.10, 0.0)]
    return note(523.25, 1.5, partials, attack=0.006, phase_seed=5)


def pop():
    """A bubble that pops: a quick upward pitch flick, gone in a quarter of a
    second."""
    out = sweep(520.0, 1560.0, 0.045, 0.25, attack=0.002, tau=0.035)
    return add(out, [0.35 * v for v in sweep(1040.0, 2600.0, 0.03, 0.12, 0.001, 0.015)])


def two_tone():
    """Two clear notes, E5 then A5: a gentle "ding-ding"."""
    partials = [(1.0, 1.0, 0.30, 0.0), (2.0, 0.28, 0.15, 0.0), (3.0, 0.08, 0.08, 0.0)]
    out = silence(0.8)
    add(out, note(659.25, 0.34, partials, attack=0.008, phase_seed=6), 0.0)
    add(out, note(880.0, 0.58, [(r, a, t * 1.4, d) for r, a, t, d in partials],
                  attack=0.008, phase_seed=7), 0.22)
    return out


def marimba():
    """A rising C-E-G on a marimba: a woody fundamental with the bar's
    quick fourth and tenth partials."""
    partials = [(1.0, 1.0, 0.22, 0.0), (3.93, 0.30, 0.035, 0.0), (9.87, 0.08, 0.012, 0.0)]
    out = silence(0.9)
    for k, freq in enumerate((523.25, 659.25, 783.99)):
        add(out, note(freq, 0.62, partials, attack=0.002, phase_seed=8 + k), 0.11 * k)
    return out


def knock():
    """Two soft knocks on a wooden door: a filtered click over a short,
    damped resonance, high enough for a phone speaker."""
    def one(seed, gain):
        body = note(640.0, 0.2, [(1.0, 0.9, 0.032, 0.0), (2.1, 0.35, 0.016, 0.0)],
                    attack=0.0015, phase_seed=seed)
        click = bandpassed_noise(0.2, 1300.0, 2.5, 0.001, 0.012, seed)
        return [gain * (b + 1.6 * c) for b, c in zip(body, click)]
    out = silence(0.45)
    add(out, one(11, 1.0), 0.0)
    add(out, one(12, 0.82), 0.17)
    return out


TONES = [
    ("codeg-chime", chime),
    ("codeg-ping", ping),
    ("codeg-glass", glass),
    ("codeg-bell", bell),
    ("codeg-pop", pop),
    ("codeg-two-tone", two_tone),
    ("codeg-marimba", marimba),
    ("codeg-knock", knock),
]


# ── Level, ends and file ──


def loudest_rms(samples, window=0.05):
    size = int(window * RATE)
    best = 0.0
    for start in range(0, max(1, len(samples) - size), size // 2):
        chunk = samples[start:start + size]
        best = max(best, math.sqrt(sum(v * v for v in chunk) / len(chunk)))
    return best


def highpass(samples, cutoff=800.0, q=0.7071):
    """Two-pole high-pass (RBJ cookbook): roughly what a phone speaker and
    the ear make of the low notes."""
    w0 = TAU * cutoff / RATE
    alpha = math.sin(w0) / (2 * q)
    c = math.cos(w0)
    b0, b1, b2 = (1 + c) / 2, -(1 + c), (1 + c) / 2
    a0, a1, a2 = 1 + alpha, -2 * c, 1 - alpha
    out = []
    x1 = x2 = y1 = y2 = 0.0
    for x0 in samples:
        y0 = (b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
        out.append(y0)
        x2, x1, y2, y1 = x1, x0, y1, y0
    return out


def loudness(samples):
    """Halfway (in dB) between the plain and the speaker-weighted level, so a
    low bell isn't left much quieter than a high ping on a phone."""
    return math.sqrt(loudest_rms(samples) * loudest_rms(highpass(samples)))


def finish(samples):
    """Match the loudness, keep the peak under MAX_PEAK, fade the last 30 ms
    to silence and end with 20 ms of it."""
    peak = max(abs(v) for v in samples) or 1.0
    gain = min(TARGET_LOUDNESS / (loudness(samples) or 1.0), MAX_PEAK / peak)
    out = [v * gain for v in samples]
    fade = int(0.03 * RATE)
    for i in range(fade):
        out[len(out) - fade + i] *= 0.5 + 0.5 * math.cos(math.pi * (i + 1) / fade)
    return out + silence(0.02)


def write_wav(path, samples, seed):
    """16-bit mono with triangular dither."""
    rng = random.Random(seed)
    frames = bytearray()
    for v in samples:
        dithered = v * 32767 + rng.random() - rng.random()
        frames += struct.pack("<h", max(-32768, min(32767, int(round(dithered)))))
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(bytes(frames))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", default=str(Path(__file__).resolve().parent.parent
                                             / "CodegiOS" / "Resources" / "Sounds"))
    args = parser.parse_args()
    if not shutil.which("afconvert"):
        sys.exit("afconvert not found: this script runs on macOS.")
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as scratch:
        for index, (name, make) in enumerate(TONES):
            samples = finish(make())
            wav = Path(scratch) / f"{name}.wav"
            caf = out_dir / f"{name}.caf"
            write_wav(wav, samples, seed=100 + index)
            subprocess.run(["afconvert", "-f", "caff", "-d", "LEI16", str(wav), str(caf)],
                           check=True)
            print(f"{caf.name}: {len(samples) / RATE:.2f} s, {caf.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
