"""
The police scanner's sound effects, synthesized.

Radio static is noise through a shaped envelope, and a squelch tail is that same
noise losing an argument with a comparator -- so these clips are built here from
sines and seeded noise rather than recorded from anything. That keeps the whole
soundscape reproducible (`random.Random(seed)`, every clip its own seed), tiny
(PCM16 mono at 22 050 Hz, seconds of audio in a few KiB each), and retunable
without an audio editor: the numbers below ARE the sound design.

The physical vocabulary, and what each clip is standing in for:

  scan-boot        the speaker waking: relay click, static wash, two-tone beep
  scan-off         the speaker dying: descending glide, static fade, relay click
  scan-squelch-N   the squelch OPENING on a carrier ("kssht") -- someone spoke
  scan-tail-N      the squelch CLOSING on a drop ("kssh-t") -- the iconic tail
  scan-channel     the between-channels sweep: two bursts and a heterodyne whine
  scan-mic-on      the fist-mic keying: relay thunk and a breath of static
  scan-mic-off     the fist-mic unkeying
  scan-detent      a knob detent ticking over
  scan-key         a rubber preset key bottoming out
  scan-denied      a dead key / a locked dial: two dull thuds, no carrier

Variants (squelch, tail) exist because a real radio never makes the same noise
twice; `sfx.ts` picks one at random per event.

Run:  python tools/scanner-sfx.py
"""

import array
import math
import os
import random
import wave

SR = 22050
OUT_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), '..', 'ui', 'public', 'audio')


def n(dur):
    return max(1, int(SR * dur))


def silence(dur):
    return [0.0] * n(dur)


def tone(dur, f0, f1=None, decay=None, amp=1.0, fade=0.005):
    """A sine with optional glide (f0->f1) and exponential decay, edge-faded."""
    count = n(dur)
    out = []
    phase = 0.0
    for i in range(count):
        f = f0 if f1 is None else f0 + (f1 - f0) * (i / count)
        phase += 2 * math.pi * f / SR
        v = math.sin(phase)
        t = i / SR
        if decay is not None:
            v *= math.exp(-t / decay)
        if fade > 0:
            v *= max(0.0, min(1.0, i / (SR * fade), (count - i) / (SR * fade)))
        out.append(v * amp)
    return out


def noise(dur, amp=1.0, seed=0, decay=None, attack=0.002):
    """Seeded white noise with an attack ramp and optional exponential decay."""
    rnd = random.Random(seed)
    count = n(dur)
    out = []
    for i in range(count):
        t = i / SR
        v = rnd.uniform(-1.0, 1.0)
        if attack > 0:
            v *= min(1.0, t / attack)
        if decay is not None:
            v *= math.exp(-max(0.0, t - attack) / decay)
        out.append(v * amp)
    return out


def lowpass(xs, k):
    y = 0.0
    out = []
    for x in xs:
        y += k * (x - y)
        out.append(y)
    return out


def highpass(xs, k):
    """One-pole highpass: the difference from its own lowpass. Twice for brightness."""
    lp = lowpass(xs, k)
    return [x - y for x, y in zip(xs, lp)]


def bright(xs):
    return highpass(highpass(xs, 0.30), 0.35)


def wobble(xs, hz=130.0, depth=0.18):
    """Amplitude wobble -- the small chaos that keeps static from sounding synthetic."""
    out = []
    for i, v in enumerate(xs):
        out.append(v * (1.0 + depth * math.sin(2 * math.pi * hz * i / SR)))
    return out


def saturate(xs, drive=2.0):
    return [math.tanh(v * drive) * 0.7 for v in xs]


def mix(*layers):
    width = max(len(v) for v in layers)
    out = [0.0] * width
    for values in layers:
        for i, v in enumerate(values):
            out[i] += v
    return out


def at(base, start, layer, gain=1.0):
    """Place a layer at a time offset inside a longer buffer (grows it as needed)."""
    i0 = n(start)
    need = i0 + len(layer)
    if need > len(base):
        base.extend([0.0] * (need - len(base)))
    for i, v in enumerate(layer):
        base[i0 + i] += v * gain
    return base


# ── the clips ───────────────────────────────────────────────────────────────

def detent():
    """A knob detent: a dry resonant tick over a click. Short and quiet by design."""
    return mix(
        tone(0.025, 2400, decay=0.007, amp=0.7),
        noise(0.010, amp=0.8, seed=11, decay=0.0025, attack=0.0005),
        tone(0.012, 700, decay=0.004, amp=0.25),
    )


def key_press():
    """A rubber preset key bottoming out: a soft low thud under a slap."""
    return mix(
        tone(0.060, 150, decay=0.030, amp=1.0),
        lowpass(noise(0.030, amp=0.6, seed=12, decay=0.006, attack=0.0008), 0.35),
    )


def denied():
    """Two dull thuds -- a key with no band behind it, a dial locked under PTT."""
    out = at(silence(0.16), 0.0, mix(
        saturate(tone(0.050, 110, decay=0.028, amp=0.9), 2.2),
        lowpass(noise(0.030, amp=0.30, seed=13, decay=0.008), 0.30),
    ))
    at(out, 0.062, mix(
        saturate(tone(0.050, 104, decay=0.024, amp=0.75), 2.2),
        lowpass(noise(0.030, amp=0.25, seed=14, decay=0.008), 0.30),
    ))
    return out


def mic_on():
    """The fist-mic keying: relay click, low thunk, and a breath of carrier."""
    return mix(
        bright(noise(0.020, amp=0.7, seed=15, decay=0.003, attack=0.0005)),
        tone(0.050, 95, decay=0.022, amp=0.8),
        at(silence(0.090), 0.006,
           lowpass(noise(0.050, amp=0.40, seed=16, decay=0.020, attack=0.003), 0.25)),
    )


def mic_off():
    """The fist-mic unkeying: a click and the carrier dropping away."""
    return mix(
        bright(noise(0.020, amp=0.6, seed=17, decay=0.003, attack=0.0005)),
        wobble(bright(noise(0.080, amp=0.5, seed=18, decay=0.030, attack=0.002)), 90),
        tone(0.030, 80, decay=0.014, amp=0.35),
    )


def squelch(seed, dur, decay):
    """The squelch opening on a carrier. Bright, fast, gone."""
    return wobble(
        bright(noise(dur, amp=1.0, seed=seed, decay=decay, attack=0.0015)), 130)


def tail(seed, dur, bump_at, bump_gain):
    """The squelch tail: a burst that almost closes, flaps once, then dies."""
    body = wobble(
        bright(noise(dur, amp=1.0, seed=seed, decay=0.045, attack=0.002)), 110)
    at(body, bump_at,
       bright(noise(0.040, amp=bump_gain, seed=seed + 50, decay=0.016, attack=0.001)))
    return body


def channel():
    """Between channels: two sweep bursts and the heterodyne whine riding past."""
    out = at(silence(0.23), 0.0, squelch(21, 0.055, 0.020))
    at(out, 0.085, squelch(22, 0.050, 0.018))
    at(out, 0.150, tone(0.060, 2200, 2650, decay=0.035, amp=0.12, fade=0.004))
    at(out, 0.205, squelch(23, 0.022, 0.008), 0.6)
    return out


def boot():
    """The speaker waking: relay click, static wash, two beeps, a settle."""
    out = at(silence(0.62), 0.0, bright(noise(0.012, amp=0.8, seed=24, decay=0.003, attack=0.0005)))
    at(out, 0.030, lowpass(noise(0.200, amp=0.5, seed=25, decay=0.110, attack=0.015), 0.25))
    at(out, 0.250, tone(0.075, 941, amp=0.35, fade=0.006))
    at(out, 0.345, tone(0.075, 1275, amp=0.35, fade=0.006))
    at(out, 0.450, squelch(26, 0.070, 0.030), 0.5)
    return out


def power_off():
    """The speaker dying: a glide down, the static fading, one last relay click."""
    out = at(silence(0.35), 0.0, tone(0.170, 620, f1=310, decay=0.090, amp=0.4, fade=0.006))
    at(out, 0.020, lowpass(noise(0.150, amp=0.3, seed=27, decay=0.055, attack=0.004), 0.25))
    at(out, 0.300, bright(noise(0.015, amp=0.6, seed=28, decay=0.004, attack=0.0005)))
    return out


CLIPS = [
    ('scan-detent.wav', detent(), 0.55),
    ('scan-key.wav', key_press(), 0.60),
    ('scan-denied.wav', denied(), 0.55),
    ('scan-mic-on.wav', mic_on(), 0.70),
    ('scan-mic-off.wav', mic_off(), 0.65),
    ('scan-squelch-1.wav', squelch(1, 0.065, 0.022), 0.50),
    ('scan-squelch-2.wav', squelch(2, 0.080, 0.030), 0.50),
    ('scan-tail-1.wav', tail(3, 0.120, 0.055, 0.45), 0.55),
    ('scan-tail-2.wav', tail(4, 0.140, 0.045, 0.35), 0.55),
    ('scan-channel.wav', channel(), 0.60),
    ('scan-boot.wav', boot(), 0.60),
    ('scan-off.wav', power_off(), 0.60),
]


def write_wav(name, samples, gain):
    peak = max(1e-9, max(abs(v) for v in samples))
    scale = gain / peak
    pcm = array.array('h')
    for v in samples:
        pcm.append(max(-32767, min(32767, int(v * scale * 32767))))
    path = os.path.join(OUT_DIR, name)
    with wave.open(path, 'wb') as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(SR)
        out.writeframes(pcm.tobytes())
    print(f'{name:22s} {len(samples) / SR * 1000:6.0f} ms  {os.path.getsize(path):6d} B')


if __name__ == '__main__':
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, samples, gain in CLIPS:
        write_wav(name, samples, gain)
    print(f'{len(CLIPS)} clips -> {os.path.normpath(OUT_DIR)}')
