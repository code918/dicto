#!/usr/bin/env python3
"""Dicto 녹음 시작/끝 효과음 생성기 (외부 음원 없이 코드로 합성, 표준 라이브러리만 사용)

- record-start.wav : 낮은음 → 높은음 두 음 (시작, 올라가는 느낌)
- record-end.wav   : 높은음 → 낮은음 두 음 (끝, 내려앉는 느낌)

부드럽게 들리는 핵심 (날카롭게 들리던 이전 버전과의 차이):
- 배음 없는 순수 사인파
- 작은 음량 (피크 약 -17dBFS). 크게 만들수록 같은 음도 쏘는 느낌이 남
- 첫 음은 두 번째 음이 나올 때 짧게 사라짐 (두 음이 겹쳐 울리면 탁하고 거슬림)
- 앞에 25ms 여백 + 부드러운 어택

실행: python3 scripts/gen_sounds.py  (또는 make sounds)
"""
import math
import os
import struct
import wave

RATE = 48000
DURATION = 0.44   # 초. 두 번째 음 여운까지 포함
LEAD = 0.025      # 시작 전 여백 (재생 직후 딸깍 방지 + 덜 급하게)
NOTE_GAP = 0.12   # 두 음 사이 간격
ATTACK = 0.015    # 소리가 피어오르는 시간
PEAK = 0.14       # 최종 피크 음량 (0~1)
OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "Dicto", "Resources")


def smoothstep(a):
    a = max(0.0, min(1.0, a))
    return a * a * (3 - 2 * a)


def note(buf, freq, start, decay, gain, cut=None):
    """buf에 사인파 한 음을 더한다. cut(초)이 있으면 그 시점에 20ms 동안 사라짐"""
    s0 = int(start * RATE)
    release = 0.02
    for idx in range(s0, len(buf)):
        t = (idx - s0) / RATE
        env = smoothstep(t / ATTACK) * math.exp(-t * decay)
        if cut is not None:
            if t >= cut + release:
                break
            if t > cut:
                env *= 1 - smoothstep((t - cut) / release)
        buf[idx] += gain * env * math.sin(2 * math.pi * freq * t)


def render(freqs, path):
    total = int(DURATION * RATE)
    mix = [0.0] * total
    first, second = freqs
    # 첫 음: 조금 느리게 줄다가 두 번째 음 직전에 사라짐
    note(mix, first, LEAD, decay=8.0, gain=0.75, cut=NOTE_GAP)
    # 두 번째 음: 살짝 크게 시작해서 더 빨리 사라짐
    note(mix, second, LEAD + NOTE_GAP, decay=13.0, gain=1.0)

    # 끝 30ms 페이드아웃 + 피크 정규화
    fade = int(0.03 * RATE)
    for i in range(fade):
        mix[total - 1 - i] *= i / fade
    peak = max(abs(x) for x in mix) or 1.0
    scale = PEAK / peak

    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        frames = bytearray()
        for x in mix:
            s = int(max(-1.0, min(1.0, x * scale)) * 32767)
            frames += struct.pack("<hh", s, s)
        w.writeframes(bytes(frames))
    print("wrote", os.path.normpath(path))


if __name__ == "__main__":
    Eb4, Bb4 = 311.13, 466.16  # 완전5도, 차분한 중저음
    render([Eb4, Bb4], os.path.join(OUT_DIR, "record-start.wav"))
    render([Bb4, Eb4], os.path.join(OUT_DIR, "record-end.wav"))
