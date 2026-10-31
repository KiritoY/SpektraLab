#!/usr/bin/env python3
"""Scalar checks for LookMatch.swift, for a machine without the Apple SDK.

The product tests are SpektrafilmTests/LookMatchTests.swift. This script
repeats the fit: exposure, black point, white point, print white balance,
histogram bins. It does not sample a crop (that is Geometry.sourcePoint,
Mac-only) and it does not decode a JPEG or touch Metal.

If the formulas in LookMatch.swift change, change them here too. The shader
contract is layer2Tone: wb gains, then c * 2^(ev/2.2), then
(c - bp/100) / max(1 - bp/100 - wp/100, 0.05).
"""

from __future__ import annotations

import math
import sys


EXPOSURE_CURVE = 2.2
BLACK_P = 0.005
MID_P = 0.50
WHITE_P = 0.995


def exposure_scale(ev: float) -> float:
    return 2.0 ** (ev / EXPOSURE_CURVE)


def tone_luma(x: float, ev: float, black: float, white: float) -> float:
    y = max(x, 0.0) * exposure_scale(ev)
    b = black / 100.0
    w = white / 100.0
    d = max(1.0 - b - w, 0.05)
    return (y - b) / d


def wb_gain(temperature: float, tint: float) -> tuple[float, float, float]:
    t = temperature / 100.0
    g = tint / 100.0
    return (1 + 0.18 * t, 1 - 0.12 * g, 1 - 0.18 * t)


def apply_tone(sample, temperature, tint, exposure, black, white):
    gr, gg, gb = wb_gain(temperature, tint)
    r, g, b = sample[0] * gr, sample[1] * gg, sample[2] * gb
    if exposure != 0:
        k = exposure_scale(exposure)
        r, g, b = max(r, 0) * k, max(g, 0) * k, max(b, 0) * k
    bp = black / 100.0
    wp = white / 100.0
    d = max(1.0 - bp - wp, 0.05)
    return ((r - bp) / d, (g - bp) / d, (b - bp) / d)


def luma(s) -> float:
    return 0.2126 * s[0] + 0.7152 * s[1] + 0.0722 * s[2]


def percentile(sorted_vals, p: float) -> float:
    n = len(sorted_vals)
    if n == 0:
        return 0.0
    if n == 1:
        return sorted_vals[0]
    x = p * (n - 1)
    i = int(math.floor(x))
    t = x - i
    if i >= n - 1:
        return sorted_vals[-1]
    return sorted_vals[i] * (1 - t) + sorted_vals[i + 1] * t


def anchors(samples):
    vals = sorted(luma(s) for s in samples)
    return (percentile(vals, BLACK_P), percentile(vals, MID_P), percentile(vals, WHITE_P))


def median(vals):
    s = sorted(vals)
    n = len(s)
    if n == 0:
        return 0.0
    if n % 2 == 1:
        return s[n // 2]
    return 0.5 * (s[n // 2 - 1] + s[n // 2])


def white_balance(source, reference):
    sr, sg, sb = median([p[0] for p in source]), median([p[1] for p in source]), median([p[2] for p in source])
    rr, rg, rb = median([p[0] for p in reference]), median([p[1] for p in reference]), median([p[2] for p in reference])
    if min(sr, sg, sb, rr, rg, rb) <= 1e-4:
        return 0.0, 0.0
    rho = (rr / rb) * (sb / sr)
    if rho <= 0:
        return 0.0, 0.0
    t = (rho - 1) / (0.18 * (rho + 1))
    temperature = min(100.0, max(-100.0, t * 100))
    u = 1 + 0.18 * (temperature / 100)
    w = (sr / sg) * u / (rr / rg)
    g = (1 - w) / 0.12
    tint = min(100.0, max(-100.0, g * 100))
    return temperature, tint


def anchor_sse(ev, black, white, src, ref) -> float:
    e0 = tone_luma(src[0], ev, black, white) - ref[0]
    e1 = tone_luma(src[1], ev, black, white) - ref[1]
    e2 = tone_luma(src[2], ev, black, white) - ref[2]
    return e0 * e0 + e1 * e1 + e2 * e2


def search(evs, blacks, whites, src, ref):
    best_sse = float("inf")
    best = (0.0, 0.0, 0.0)
    for ev in evs:
        for black in blacks:
            for white in whites:
                sse = anchor_sse(ev, black, white, src, ref)
                if sse + 1e-8 < best_sse:
                    best_sse = sse
                    best = (ev, black, white)
                elif sse <= best_sse + 1e-8:
                    candidate = (white, black, abs(ev))
                    current = (best[2], best[1], abs(best[0]))
                    if candidate < current:
                        best_sse = min(best_sse, sse)
                        best = (ev, black, white)
    return best


def exposure_matching_mid(source, reference) -> float:
    if source <= 1e-4:
        return 0.0
    ratio = max(reference, 1e-6) / source
    return min(3.0, max(-3.0, EXPOSURE_CURVE * math.log2(ratio)))


def fit_tone(src, ref):
    if src[2] - src[0] < 1e-3 or abs(ref[2] - ref[0]) < 1e-3:
        return (exposure_matching_mid(src[1], ref[1]), 0.0, 0.0)
    evs = [-3 + i * 0.25 for i in range(25)]
    points = [float(i) for i in range(0, 51, 2)]
    ev, black, white = search(evs, points, points, src, ref)
    for step_e, step_p, radius in ((0.05, 0.5, 4), (0.01, 0.1, 5)):
        evs = [min(3, max(-3, ev + (i - radius) * step_e)) for i in range(radius * 2 + 1)]
        blacks = [min(50, max(0, black + (i - radius) * step_p)) for i in range(radius * 2 + 1)]
        whites = [min(50, max(0, white + (i - radius) * step_p)) for i in range(radius * 2 + 1)]
        ev, black, white = search(evs, blacks, whites, src, ref)
    return ev, black, white


def propose(source, reference, match_wb: bool):
    if len(source) < 8 or len(reference) < 8:
        return None
    temperature = tint = 0.0
    graded = source
    if match_wb:
        temperature, tint = white_balance(source, reference)
        gain = wb_gain(temperature, tint)
        graded = [(p[0] * gain[0], p[1] * gain[1], p[2] * gain[2]) for p in source]
    src = anchors(graded)
    ref = anchors(reference)
    ev, black, white = fit_tone(src, ref)
    pred = (
        tone_luma(src[0], ev, black, white),
        tone_luma(src[1], ev, black, white),
        tone_luma(src[2], ev, black, white),
    )
    err = tuple(abs(pred[i] - ref[i]) for i in range(3))
    return {"ev": ev, "black": black, "white": white, "temp": temperature, "tint": tint, "err": err}


def ramp(n=401, exposure=0.0, black=0.0, white=0.0):
    out = []
    for i in range(n):
        x = 0.02 + 0.96 * i / (n - 1)
        out.append(apply_tone((x, x, x), 0, 0, exposure, black, white))
    return out


def bin_index(v: float) -> int:
    x = min(1.0, max(0.0, v))
    return min(255, max(0, int(x * 255 + 0.5)))


def check(cond, message):
    if not cond:
        raise SystemExit(message)


def main() -> None:
    identity = propose(ramp(), ramp(), False)
    check(abs(identity["ev"]) < 0.02 and abs(identity["black"]) < 0.2 and abs(identity["white"]) < 0.2, "identity")

    for ev, black, white in (
        (1, 0, 0), (-1.5, 0, 0), (2.5, 0, 0),
        (0, 12, 0), (0.5, 14, 0),
        (0, 10, 12), (0.75, 8, 6), (-1, 20, 18), (0, 4, 22),
    ):
        got = propose(ramp(), ramp(exposure=ev, black=black, white=white), False)
        check(abs(got["ev"] - ev) < 0.05, f"ev {ev} -> {got['ev']}")
        check(abs(got["black"] - black) < 0.5, f"black {black} -> {got['black']}")
        check(abs(got["white"] - white) < 0.5, f"white {white} -> {got['white']}")
        check(max(got["err"]) < 0.002, f"anchors {ev, black, white} {got['err']}")

    scale = propose(ramp(), ramp(white=15), False)
    check(max(scale["err"]) < 0.002 and abs(scale["black"]) < 0.5, f"white-point scale {scale}")

    flat_s = [(0.2, 0.2, 0.2)] * 32
    flat_r = [(0.4, 0.4, 0.4)] * 32
    flat = propose(flat_s, flat_r, False)
    check(abs(flat["ev"] - 2.2) < 0.001 and flat["black"] == 0 and flat["white"] == 0, f"flat {flat}")
    check(propose([(0.2, 0.2, 0.2)], ramp(), False) is None, "too few")

    source = [(0.2 + 0.6 * i / 50,) * 3 for i in range(51)]
    for temperature, tint in ((20, 0), (-40, 0), (0, 25), (15, -10), (80, 40)):
        reference = [apply_tone(p, temperature, tint, 0, 0, 0) for p in source]
        got = propose(source, reference, True)
        check(abs(got["temp"] - temperature) < 0.5, f"temp {temperature} -> {got['temp']}")
        check(abs(got["tint"] - tint) < 0.5, f"tint {tint} -> {got['tint']}")
        check(abs(got["ev"]) < 0.05, f"wb exposure {got['ev']}")

    red = (1.0, 0.0, 0.0)
    check(bin_index(luma(red)) == 54, f"luma bin {bin_index(luma(red))}")
    check(bin_index(1) == 255 and bin_index(0) == 0, "end bins")
    print("look-match scalar checks ok")


if __name__ == "__main__":
    main()
