#!/usr/bin/env python3
# ===========================================================================
# clawbar-vad.py — trailing-silence Voice Activity Detector for clawbar.
#
# Reads raw mono 16-bit little-endian PCM @ 16 kHz from STDIN (produced by
#   ffmpeg -f pulse -i default -ar 16000 -ac 1 -f s16le -
# ), computes RMS energy per ~30 ms frame in dBFS, and:
#   * waits for speech to begin (frames above the threshold),
#   * once at least MIN_SPEECH_MS of speech has accumulated, watches for
#     SILENCE_MS of continuous silence,
#   * exits 0 when that trailing silence is detected (-> caller stops & sends),
#   * exits 2 if no speech ever started within START_GRACE_MS,
#   * exits 1 on EOF / read error.
#
# It deliberately does NOT cut on the initial silence before the user speaks.
# Tunables come from the environment (set by claw-talk):
#   CLAWBAR_VAD_SILENCE_MS, CLAWBAR_VAD_THRESH_DB,
#   CLAWBAR_VAD_MIN_SPEECH_MS, CLAWBAR_VAD_START_GRACE_MS
#
# Also runnable standalone for testing:
#   clawbar-vad.py --selftest        # synthetic speech+silence, asserts exit 0
#   clawbar-vad.py --wav file.wav    # feed a 16k mono PCM WAV, prints decision
# ===========================================================================
import math
import os
import struct
import sys

SAMPLE_RATE = 16000
FRAME_MS = 30
FRAME_SAMPLES = SAMPLE_RATE * FRAME_MS // 1000  # 480
FRAME_BYTES = FRAME_SAMPLES * 2                  # 16-bit


def _env_int(name, default):
    try:
        return int(float(os.environ.get(name, default)))
    except (TypeError, ValueError):
        return default


def _env_float(name, default):
    try:
        return float(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


SILENCE_MS = _env_int("CLAWBAR_VAD_SILENCE_MS", 1500)
THRESH_DB = _env_float("CLAWBAR_VAD_THRESH_DB", -38.0)
MIN_SPEECH_MS = _env_int("CLAWBAR_VAD_MIN_SPEECH_MS", 300)
START_GRACE_MS = _env_int("CLAWBAR_VAD_START_GRACE_MS", 8000)


def rms_dbfs(frame_bytes):
    """RMS of a frame of s16le samples, in dBFS (full scale = 32768)."""
    n = len(frame_bytes) // 2
    if n == 0:
        return -120.0
    samples = struct.unpack("<%dh" % n, frame_bytes[: n * 2])
    acc = 0.0
    for s in samples:
        acc += float(s) * float(s)
    rms = math.sqrt(acc / n)
    if rms < 1.0:
        return -120.0
    return 20.0 * math.log10(rms / 32768.0)


def decide(frame_iter,
           silence_ms=SILENCE_MS,
           thresh_db=THRESH_DB,
           min_speech_ms=MIN_SPEECH_MS,
           start_grace_ms=START_GRACE_MS):
    """Consume frames (bytes) and return an exit code.

    0 -> trailing silence after speech (stop & send)
    2 -> no speech started within the start grace window
    1 -> stream ended before a decision
    """
    speech_ms = 0
    silence_run_ms = 0
    elapsed_ms = 0
    started = False

    for frame in frame_iter:
        if len(frame) < FRAME_BYTES:
            break
        elapsed_ms += FRAME_MS
        db = rms_dbfs(frame)
        is_speech = db >= thresh_db

        if is_speech:
            speech_ms += FRAME_MS
            silence_run_ms = 0
            if speech_ms >= min_speech_ms:
                started = True
        else:
            if started:
                silence_run_ms += FRAME_MS
                if silence_run_ms >= silence_ms:
                    return 0  # done: trailing silence detected

        if not started and elapsed_ms >= start_grace_ms:
            return 2  # user never started talking

    return 1  # EOF without a decision


def _frames_from_stdin():
    fh = sys.stdin.buffer
    while True:
        chunk = fh.read(FRAME_BYTES)
        if not chunk:
            return
        yield chunk


def _frames_from_bytes(data):
    for i in range(0, len(data) - FRAME_BYTES + 1, FRAME_BYTES):
        yield data[i:i + FRAME_BYTES]


def _gen_pcm(seconds, amplitude=0, freq=220.0):
    """Generate s16le mono PCM. amplitude 0 = pure silence."""
    out = bytearray()
    total = int(SAMPLE_RATE * seconds)
    for i in range(total):
        if amplitude:
            val = int(amplitude * math.sin(2 * math.pi * freq * (i / SAMPLE_RATE)))
        else:
            val = 0
        out += struct.pack("<h", max(-32768, min(32767, val)))
    return bytes(out)


def _selftest():
    # 0.2s lead silence, 1.0s speech, 2.0s trailing silence -> expect exit 0.
    data = (_gen_pcm(0.2, 0)
            + _gen_pcm(1.0, 12000)
            + _gen_pcm(2.0, 0))
    code = decide(_frames_from_bytes(data))
    print("selftest speech+silence -> exit %d (expect 0)" % code)
    ok = (code == 0)

    # pure silence the whole time -> expect exit 2 (never started)
    data2 = _gen_pcm(float(START_GRACE_MS) / 1000.0 + 1.0, 0)
    code2 = decide(_frames_from_bytes(data2))
    print("selftest pure-silence -> exit %d (expect 2)" % code2)
    ok = ok and (code2 == 2)

    # speech that never goes silent long enough -> EOF -> exit 1
    data3 = _gen_pcm(0.2, 0) + _gen_pcm(1.0, 12000)
    code3 = decide(_frames_from_bytes(data3))
    print("selftest speech-no-trailing-silence -> exit %d (expect 1)" % code3)
    ok = ok and (code3 == 1)

    print("SELFTEST", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def _from_wav(path):
    import wave
    with wave.open(path, "rb") as w:
        if w.getframerate() != SAMPLE_RATE or w.getnchannels() != 1 or w.getsampwidth() != 2:
            sys.stderr.write("warn: expected 16k mono s16 WAV; got "
                             "%dHz %dch %dbytes\n" %
                             (w.getframerate(), w.getnchannels(), w.getsampwidth()))
        data = w.readframes(w.getnframes())
    code = decide(_frames_from_bytes(data))
    print("wav decision -> exit %d" % code)
    return code


def main(argv):
    if "--selftest" in argv:
        return _selftest()
    if "--wav" in argv:
        i = argv.index("--wav")
        return _from_wav(argv[i + 1])
    return decide(_frames_from_stdin())


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
