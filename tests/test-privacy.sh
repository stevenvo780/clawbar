#!/usr/bin/env bash
# Black-box privacy regressions. Every audio/network/desktop tool is a mock;
# the only audio bytes are generated silence and a synthetic tone.
# Usage: bash tests/test-privacy.sh [path/to/bin/claw-talk]
# CLAWBAR_TEST_EVIDENCE=/absolute/path preserves isolated runs and their logs.
# CLAWBAR_TEST_CASES=name,name selects individual cases while debugging.
set -euo pipefail
target="${1:-$(cd "$(dirname "$0")/../bin" && pwd)/claw-talk}"
exec python3 - "$target" <<'PY'
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

target = Path(sys.argv[1]).resolve()
if not target.is_file():
    raise SystemExit("Missing claw-talk: " + str(target))
for tool in ("bash", "python3", "jq"):
    if shutil.which(tool) is None:
        raise SystemExit("Missing test dependency: " + tool)
evidence = os.environ.get("CLAWBAR_TEST_EVIDENCE")
root = Path(evidence).resolve() if evidence else Path(tempfile.mkdtemp(prefix="clawbar-privacy-"))
root.mkdir(parents=True, exist_ok=True)
failures = []
cases = []

# One dispatcher is installed under every external command that can touch
# audio, containers, the network, notifications, or desktop pixels.
mock_source = r'''#!/usr/bin/python3
import json, math, os, signal, struct, sys, time, wave
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
base = Path(os.environ["CLAWBAR_TEST_CASE"])
pid = os.getpid()
def event(kind, **fields):
    entry = dict(kind=kind, pid=pid, tool=name, args=args, **fields)
    with (base / "events.jsonl").open("a") as f:
        f.write(json.dumps(entry) + "\n")
def wait_gate(gate):
    while not gate.exists():
        time.sleep(0.01)
def finish(signum, frame):
    event("terminated", signal=signum)
    raise SystemExit(0)
signal.signal(signal.SIGINT, finish)
signal.signal(signal.SIGTERM, finish)
event("started")
if name == "pw-record":
    out = Path(args[-1])
    if (base / "recorder.block").exists():
        event("recorder_wait")
        wait_gate(base / "recorder.release")
    with wave.open(str(out), "wb") as wav:
        wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(16000)
        wav.writeframes(b"\x00\x00" * 1600)
    event("recording", output=str(out))
    (base / ("recorder.%d.ready" % pid)).touch()
    while True: time.sleep(0.05)
elif name == "sleep":
    if args == ["54321"]:
        event("cap_wait")
        wait_gate(base / ("cap.%d.release" % pid))
        event("cap_released")
    elif args == ["0.4"] and (base / "flush.block").exists():
        event("flush_wait")
        wait_gate(base / "flush.release")
    else:
        time.sleep(min(float(args[0]), 0.05))
elif name == "curl":
    if any("/audio/transcriptions" in a for a in args):
        event("stt")
        if (base / "stt.block").exists(): wait_gate(base / "stt.release")
        print(json.dumps({"text": "synthetic spoken turn"}))
    elif any("/audio/speech" in a for a in args):
        event("tts")
        if "-o" in args: Path(args[args.index("-o") + 1]).write_bytes(b"synthetic tts")
    else:
        event("unexpected_curl"); raise SystemExit(90)
elif name == "docker":
    if args and args[0] == "inspect": print("127.0.0.77")
    elif args and args[0] == "exec":
        event("agent")
        print(json.dumps({"result": {"payloads": [{"text": "synthetic reply"}]}}))
    else:
        event("unexpected_docker"); raise SystemExit(91)
elif name == "ffmpeg":
    event("vad_wait")
    wait_gate(base / ("vad.%d.release" % pid))
    if (base / "vad.silence").exists():
        # Enough generated silence to reach the detector's no-speech exit 2.
        data = b"\x00\x00" * (16000 * 9)
    else:
        # 1 s of generated tone followed by 2 s of generated silence.
        data = bytearray()
        for i in range(16000): data += struct.pack("<h", int(12000 * math.sin(2 * math.pi * 220 * i / 16000)))
        data += b"\x00\x00" * 32000
    try:
        sys.stdout.buffer.write(data); sys.stdout.buffer.flush()
    except BrokenPipeError:
        # The detector intentionally closes once it has enough PCM. Avoid a
        # second buffered flush making this finite synthetic producer fail.
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
    event("vad_released")
elif name == "pkill":
    # Waybar notifications never touch the host. -P is restricted to direct
    # children recorded by this case's mocks; it cannot kill a host process.
    if "-P" in args and len(args) in (2, 3) and args[args.index("-P") + 1].isdigit():
        parent = int(args[args.index("-P") + 1])
        for line in (base / "events.jsonl").read_text().splitlines():
            try:
                child = json.loads(line)["pid"]
                stat = Path("/proc/%d/stat" % child).read_text().rsplit(")", 1)[1].split()
                if int(stat[1]) == parent: os.kill(child, signal.SIGTERM)
            except (FileNotFoundError, ProcessLookupError, ValueError, KeyError): pass
elif name == "python3":
    # Track the synthetic VAD consumer too, then preserve its PID while
    # executing the real detector against the mocked PCM stream.
    os.execv("/usr/bin/python3", ["python3", *args])
elif name in ("spectacle", "grim", "magick", "convert"):
    event("screenshot"); raise SystemExit(92)
elif name == "notify-send":
    if any("Escuchando" in arg for arg in args) and (base / "start.block").exists():
        event("start_wait")
        wait_gate(base / "start.release")
elif name in ("canberra-gtk-play", "paplay", "pw-play"):
    pass
else:
    event("unexpected_tool"); raise SystemExit(93)
'''

def alive(pid):
    try:
        stat = Path("/proc/%d/stat" % pid).read_text().rsplit(")", 1)[1].split()
        return stat[0] != "Z"
    except FileNotFoundError:
        return False

def wait_for(predicate, description, timeout=3):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    raise AssertionError("timed out waiting for " + description)

class Case:
    def __init__(self, name, vad=False):
        self.name = name
        self.base = root / name
        if self.base.exists():
            raise SystemExit("Refusing to reuse test case directory: " + str(self.base))
        self.base.mkdir()
        self.home = self.base / "home"; self.home.mkdir()
        self.runtime = self.base / "runtime"; self.runtime.mkdir()
        self.mocks = self.base / "mocks"; self.mocks.mkdir()
        self.events = self.base / "events.jsonl"; self.events.touch()
        dispatcher = self.mocks / "dispatcher"
        dispatcher.write_text(mock_source); dispatcher.chmod(0o755)
        for tool in ("pw-record", "curl", "docker", "ffmpeg", "sleep", "notify-send",
                     "pkill", "python3", "canberra-gtk-play", "paplay", "pw-play", "spectacle", "grim", "magick", "convert"):
            (self.mocks / tool).symlink_to(dispatcher.name)
        cfg = self.base / "clawbar.env"
        cfg.write_text("CLAWBAR_VAD=%s\nMAX_REC_SECS=54321\nSHOT_HOSTDIR=%s\n" %
                       ("on" if vad else "off", self.base / "screenshots"))
        # Do not inherit credentials or configuration from the caller.
        self.env = {"HOME": str(self.home), "PATH": str(self.mocks) + ":/usr/bin:/bin",
                    "XDG_RUNTIME_DIR": str(self.runtime), "CLAWBAR_ENV": str(cfg),
                    "CLAWBAR_TEST_CASE": str(self.base), "LANG": "C.UTF-8",
                    "TMPDIR": str(self.base), "DISPLAY": ":synthetic", "WAYLAND_DISPLAY": "synthetic",
                    "DBUS_SESSION_BUS_ADDRESS": "unix:path=" + str(self.runtime / "synthetic-bus")}
        self.groups = []
        self.processes = []
        self.cleaned = False
        self.pid_file = self.runtime / "claw-talk.recpid"
        self.wav_file = self.runtime / "claw-talk.rec.wav"
        cases.append(self)

    def entries(self, kind):
        result = []
        for line in self.events.read_text().splitlines():
            try:
                row = json.loads(line)
                if row["kind"] == kind: result.append(row)
            except json.JSONDecodeError: pass
        return result

    def command(self, *args, background=False):
        out = (self.base / "commands.log").open("a")
        out.write("$ claw-talk " + " ".join(args) + "\n"); out.flush()
        proc = subprocess.Popen(["/usr/bin/bash", str(target), *args], env=self.env,
                                stdout=out, stderr=out, start_new_session=True)
        out.close()
        self.groups.append(proc.pid); self.processes.append(proc)
        if background: return proc
        proc.wait(timeout=15)
        self.check(proc.returncode == 0, "command succeeded: " + " ".join(args))
        return proc

    def check(self, condition, message):
        line = ("PASS " if condition else "FAIL ") + self.name + ": " + message
        print(line, flush=True)
        with (root / "results.log").open("a") as f: f.write(line + "\n")
        if not condition: failures.append(line)

    def start(self):
        self.command("start")
        wait_for(lambda: self.pid_file.exists() and self.pid_file.read_text().strip(), "recording PID")
        pid = int(self.pid_file.read_text())
        wait_for(lambda: (self.base / ("recorder.%d.ready" % pid)).exists(), "mock recorder ready")
        wait_for(lambda: len(self.entries("cap_wait")) >= len(self.entries("recording")), "hard cap ready")
        self.check(alive(pid), "synthetic recorder started")
        return pid

    def discarded(self, pid):
        # Poll for asynchronous cancellation, but retain all independent
        # assertions so the vulnerable base records the complete failure.
        until = time.monotonic() + 1
        while alive(pid) and time.monotonic() < until: time.sleep(0.01)
        self.check(not alive(pid), "privacy stops active recorder")
        self.check(not self.pid_file.exists(), "discarded recorder PID removed")
        self.check(not self.wav_file.exists(), "discarded synthetic WAV removed")
        self.check(not list(self.runtime.rglob("*.wav")), "no cancelled audio remains in runtime directories")

    def cleanup(self):
        if self.cleaned: return
        self.cleaned = True
        for group in self.groups:
            try: os.killpg(group, signal.SIGTERM)
            except ProcessLookupError: pass
        # A production implementation may deliberately create a VAD session.
        # Only explicitly logged mock PIDs belonging to this case are stopped.
        for row in self.entries("started"):
            if alive(row["pid"]):
                try: os.kill(row["pid"], signal.SIGTERM)
                except ProcessLookupError: pass
        for proc in self.processes:
            try: proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                try: os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                proc.wait(timeout=1)

def discard_active(action):
    case = Case("active-" + "-".join(action))
    try:
        pid = case.start()
        case.command(*action)
        case.discarded(pid)
        before_recorders = len(case.entries("recording"))
        case.command("start")
        case.check(len(case.entries("recording")) == before_recorders, "muted microphone cannot start another recording")
        case.command("stop")
        case.command("mute", "off")
        case.command("stop")
        case.check(not case.entries("stt"), "discarded turn never transcribed, including unmute + stop")
        case.check(not case.entries("agent"), "discarded turn never sent, including unmute + stop")
        case.start()
        before_stt, before_agent = len(case.entries("stt")), len(case.entries("agent"))
        case.command("stop")
        case.check(len(case.entries("stt")) == before_stt + 1, "unmute allows fresh transcription")
        case.check(len(case.entries("agent")) == before_agent + 1, "unmute allows fresh agent turn")
    finally: case.cleanup()

def interrupt_processing(stage):
    case = Case("privacy-during-" + stage)
    try:
        pid = case.start()
        (case.base / (stage + ".block")).touch()
        stop = case.command("stop", background=True)
        wait_for(lambda: case.entries("flush_wait" if stage == "flush" else "stt"), stage + " blocked")
        case.command("privacy")
        case.check(not case.wav_file.exists(), "privacy removes WAV during " + stage)
        # Immediately resume microphone permission: the discarded generation
        # must remain cancelled even though its muted flag disappears.
        case.command("mute", "off")
        (case.base / (stage + ".release")).touch()
        stop.wait(timeout=15)
        case.check(not case.entries("agent"), "discarded " + stage + " turn never sent after unmute")
        if stage == "flush": case.check(not case.entries("stt"), "discarded flush turn never transcribed")
        case.command("stop")
        case.check(not case.entries("agent"), "later stop cannot revive discarded " + stage + " turn")
        case.check(not list(case.runtime.rglob("*.wav")), "no cancelled " + stage + " audio remains")
        case.start()
        before_agent = len(case.entries("agent"))
        case.command("stop")
        case.check(len(case.entries("agent")) == before_agent + 1, "fresh turn sends after " + stage + " cancellation")
    finally: case.cleanup()

def privacy_during_start():
    case = Case("privacy-during-start")
    try:
        (case.base / "recorder.block").touch()
        (case.base / "start.block").touch()
        start = case.command("start", background=True)
        wait_for(lambda: case.entries("recorder_wait") and case.entries("start_wait"),
                 "start published its recorder but mock has not written audio")
        pid = case.entries("recorder_wait")[0]["pid"]
        privacy = case.command("privacy", background=True)
        (case.base / "start.release").touch()
        start.wait(timeout=15); privacy.wait(timeout=15)
        case.check(start.returncode == 0 and privacy.returncode == 0, "concurrent start and privacy completed")
        (case.base / "recorder.release").touch()
        case.discarded(pid)
        case.command("stop")
        case.check(not case.entries("stt"), "cancelled startup turn never transcribed")
        case.check(not case.entries("agent"), "cancelled startup turn never sent")
        case.command("mute", "off")
        case.start()
        case.command("stop")
        case.check(len(case.entries("agent")) == 1, "fresh turn sends after startup cancellation")
    finally: case.cleanup()

def stale_cap():
    case = Case("stale-hard-cap")
    try:
        first = case.start()
        old = case.entries("cap_wait")[0]["pid"]
        case.command("stop")
        second = case.start()
        (case.base / ("cap.%d.release" % old)).touch()
        time.sleep(0.2)
        case.check(alive(second), "old hard cap cannot kill fresh recording")
        case.check(case.pid_file.exists() and int(case.pid_file.read_text()) == second,
                   "old hard cap preserves fresh recorder ownership")
        current = case.entries("cap_wait")[-1]["pid"]
        (case.base / ("cap.%d.release" % current)).touch()
        wait_for(lambda: not alive(second), "current hard cap stops its recorder")
        case.check(True, "current hard cap still stops its own recording")
    finally: case.cleanup()

def vad_cleanup():
    case = Case("privacy-vad-cleanup", vad=True)
    try:
        first = case.start()
        wait_for(lambda: case.entries("vad_wait"), "first synthetic VAD stream")
        old = case.entries("vad_wait")[0]["pid"]
        case.command("privacy")
        case.discarded(first)
        time.sleep(0.1)
        case.check(not alive(old), "privacy stops synthetic VAD pipeline producer")
        case.check(not any(alive(row["pid"]) for row in case.entries("started") if row["tool"] == "python3"),
                   "privacy stops synthetic VAD pipeline consumer")
        case.check(not (case.runtime / "claw-talk.vadpid").exists(), "privacy removes VAD PID")
        case.command("mute", "off")
        second = case.start()
        wait_for(lambda: len(case.entries("vad_wait")) >= 2, "fresh synthetic VAD stream")
        (case.base / ("vad.%d.release" % old)).touch()
        time.sleep(0.2)
        case.check(alive(second), "old VAD callback cannot stop fresh recording")
        case.check(not case.entries("agent"), "old VAD callback cannot send discarded turn")
        current = case.entries("vad_wait")[-1]["pid"]
        (case.base / ("vad.%d.release" % current)).touch()
        wait_for(lambda: case.entries("agent"), "fresh synthetic VAD sends its own turn")
        case.check(len(case.entries("agent")) == 1, "fresh VAD session sends once")
    finally: case.cleanup()

def vad_no_speech():
    case = Case("vad-no-speech", vad=True)
    try:
        (case.base / "vad.silence").touch()
        first = case.start()
        vad_file = case.runtime / "claw-talk.vadpid"
        wait_for(lambda: case.entries("vad_wait") and vad_file.exists(), "synthetic no-speech VAD ready")
        supervisor = int(vad_file.read_text())
        producer = case.entries("vad_wait")[-1]["pid"]
        (case.base / ("vad.%d.release" % producer)).touch()
        wait_for(lambda: not alive(supervisor), "no-speech VAD supervisor exits")
        case.check(not vad_file.exists(), "no-speech VAD removes published PID")
        case.check(not list(case.runtime.rglob("vadpid")), "no-speech VAD removes per-turn supervisor PID")
        case.check(alive(first), "no-speech VAD leaves manual recording available")
        case.check(not case.entries("stt") and not case.entries("agent"), "no-speech VAD never processes or sends")
        case.command("stop")
        case.check(len(case.entries("agent")) == 1, "manual stop works after no-speech VAD exit")
        second = case.start()
        case.command("mute", "on")
        case.discarded(second)
        case.check(len(case.entries("agent")) == 1, "mute still discards the restarted recording")
        case.command("mute", "off")
        case.start()
        case.command("stop")
        case.check(len(case.entries("agent")) == 2, "unmute and restart work after no-speech VAD exit")
    finally: case.cleanup()

tests = [("active-" + "-".join(action), lambda action=action: discard_active(action))
         for action in (("mute", "on"), ("mute", "toggle"), ("privacy",))]
tests += [("privacy-during-" + stage, lambda stage=stage: interrupt_processing(stage))
          for stage in ("flush", "stt")]
tests += [("privacy-during-start", privacy_during_start),
          ("stale-hard-cap", stale_cap), ("privacy-vad-cleanup", vad_cleanup),
          ("vad-no-speech", vad_no_speech)]
selected = set(os.environ.get("CLAWBAR_TEST_CASES", "").split(",")) - {""}
if selected - {name for name, _ in tests}:
    raise SystemExit("Unknown selected test case")
for name, run in tests:
    if selected and name not in selected: continue
    try: run()
    except (AssertionError, subprocess.TimeoutExpired) as error:
        line = "HARNESS FAIL " + name + ": " + str(error)
        failures.append(line); print(line, flush=True)
        with (root / "results.log").open("a") as f: f.write(line + "\n")

print("RESULT: %d failure(s); evidence=%s" % (len(failures), root), flush=True)
if not evidence:
    shutil.rmtree(root)
sys.exit(1 if failures else 0)
PY
