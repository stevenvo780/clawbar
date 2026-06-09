# clawbar

A small, self-contained **voice + status integration for [OpenClaw]** on a
Wayland desktop (Hyprland + [waybar]). It turns an OpenClaw agent running in a
Docker container into a hands-free desktop assistant:

- **Push-to-talk or hands-free (VAD):** press a key to start talking; clawbar
  records your mic, **auto-stops on silence** (Voice Activity Detection),
  transcribes (Whisper), optionally looks at your screen, asks the agent, and
  **speaks the reply back** (Kokoro TTS).
- **A waybar module** that shows what the assistant is doing in real time with a
  per-phase icon, colour and animation — `🐾 idle`, `🎙 listening`,
  `📝 transcribing`, `👁 looking`, `🤔 thinking`, `🗣 speaking`, `⚠ error`.
- **One-click actions** from the bar: left-click to talk, right-click to open
  the dashboard, middle-click to drop into the agent's terminal.

It is intentionally thin: it never modifies the agent container. It talks to the
agent with `docker exec`, and to a small audio sidecar (Whisper STT + Kokoro
TTS) over plain HTTP on the container's docker network. The agent stays
isolated.

> [OpenClaw]: https://github.com/openclaw/openclaw — the agent runtime this
> wraps. clawbar is unaffiliated; it just integrates with a running instance.
> [waybar]: https://github.com/Alexays/Waybar

---

## Features

| | |
|---|---|
| **VAD auto-stop** | Background detector listens for trailing silence and ends the turn ~1.5 s after you stop talking. Tunable. Manual toggle still works as override. |
| **Live waybar status** | `clawbar-status` emits waybar JSON; `claw-talk` pushes `SIGRTMIN+8` on every phase change so the icon updates instantly. |
| **Vision on demand** | If you say "look at the screen" (configurable regex, ES/EN), it grabs a screenshot, downscales it, and hands it to the agent to read. |
| **Speak back** | Replies are synthesized with Kokoro TTS and played on your default sink. |
| **Zero secrets** | No tokens in config or repo. The agent's auth lives in the container/your secret store. |
| **Idempotent install** | Backs up every file it touches, validates waybar still parses, reverts on failure. `uninstall.sh` restores. |

---

## Requirements

- Linux desktop with **PipeWire** (`pw-record`, `pw-play` / `paplay`).
- **waybar** and (for the keybind) **Hyprland** — though `claw-talk` works on
  any session; only the bar module and bind are waybar/Hyprland specific.
- **ffmpeg** and **python3** (for VAD), **jq**, **curl**, **notify-send**.
- **Docker**, with:
  - an OpenClaw agent container (default name `claw`) exposing
    `openclaw agent`,
  - an audio sidecar container (default name `claw-audio`) serving an
    OpenAI-compatible `/v1/audio/transcriptions` and `/v1/audio/speech`
    (e.g. [speaches] with faster-whisper + Kokoro).
- Optional: `spectacle` or `grim` + ImageMagick (`magick`/`convert`) for the
  screen-vision feature.

> [speaches]: https://github.com/speaches-ai/speaches

---

## Install

```bash
git clone https://github.com/stevenvo780/clawbar.git
cd clawbar
./install.sh
```

The installer:

1. copies `bin/claw-talk`, `bin/clawbar-vad.py`, `bin/clawbar-status` to
   `~/.local/bin/` (and, if present, deploys `claw-talk` over a legacy path,
   with a backup),
2. creates `~/.config/clawbar/clawbar.env` from the example (only if absent),
3. merges the `custom/claw` module into your waybar config + modules file,
   rewriting the click commands to your launchers, then **validates** waybar
   still parses (reverts that step if not),
4. appends the styles to your waybar `style.css`,
5. adds the Hyprland keybind **only if** no `claw-talk` bind exists yet,
6. reloads waybar (`SIGUSR2`) and runs `hyprctl reload`.

Everything is backed up as `*.bak-clawbar-<timestamp>`. Re-running is safe.

Override any path/target via env, e.g.:

```bash
CLAWBAR_BIN_DIR=~/bin \
CLAWBAR_WAYBAR_BAR_ARRAY=modules-center \
CLAWBAR_CLICK_RIGHT='~/.local/bin/chat-claw.sh' \
./install.sh
```

### Uninstall

```bash
./uninstall.sh
```

Restores the newest `*.bak-clawbar-*` for each file and removes the installed
scripts. Your `clawbar.env` is kept.

---

## Configuration

All knobs live in `clawbar.env` (copy from `clawbar.env.example`). **No secrets.**
Highlights:

```ini
CLAW_CTR=claw            # agent container
AUDIO_CTR=claw-audio     # STT/TTS sidecar
VOICE=ef_dora            # Kokoro voice
LANG_STT=es              # Whisper language

CLAWBAR_VAD=on           # hands-free auto-stop
VAD_SILENCE_MS=1500      # trailing silence to end the turn
VAD_THRESH_DB=-38        # speech threshold (dBFS)
VAD_MIN_SPEECH_MS=300    # min speech before the cutoff arms

CLAWBAR_WAYBAR_SIGNAL=8  # must match "signal" in the waybar module
```

`claw-talk` looks for `clawbar.env` at `$CLAWBAR_ENV`, next to the script,
`~/.config/clawbar/clawbar.env`, then a couple of legacy locations.

---

## Usage

| Action | How |
|---|---|
| Talk (toggle / hands-free) | `SUPER+SHIFT+V`, or left-click the bar icon, or `claw-talk toggle` |
| Force-send now | press the key again while recording (overrides VAD) |
| Open dashboard | right-click the bar icon |
| Agent terminal (TUI) | middle-click the bar icon |
| Speak arbitrary text | `claw-talk say "hola"` |
| Self-check | `claw-talk test` |
| Read current phase | `claw-talk state` |

Say something like *"mirá la pantalla y decime qué ves"* to trigger the
screen-vision path.

### Status icons / classes

| State | Icon | waybar class |
|---|---|---|
| idle | 🐾 | `idle` |
| listening | 🎙 | `listening` |
| transcribing | 📝 | `transcribing` |
| looking | 👁 | `looking` |
| thinking | 🤔 | `thinking` |
| speaking | 🗣 | `speaking` |
| error | ⚠ | `error` |

Style each via `#custom-claw.<class>` in your waybar CSS (defaults shipped in
`waybar/style.css`, with pulse/blink animations for listening/thinking/
speaking/error).

---

## How the VAD works

`bin/clawbar-vad.py` reads raw 16 kHz mono PCM from `ffmpeg -f pulse` and
computes RMS energy in dBFS per 30 ms frame. It:

1. **waits for speech to begin** (never cuts on the initial silence),
2. once at least `VAD_MIN_SPEECH_MS` of speech has accumulated, watches for
   `VAD_SILENCE_MS` of continuous silence,
3. exits `0` on that trailing silence → `claw-talk` ends the turn and sends it,
4. exits `2` if you never start talking within `VAD_START_GRACE_MS`, `1` on EOF.

It runs in parallel with the recorder and only fires once; the manual toggle and
the `MAX_REC_SECS` hard cap remain as fallbacks. Test it without a mic:

```bash
python3 bin/clawbar-vad.py --selftest      # synthetic speech+silence
python3 bin/clawbar-vad.py --wav some.wav  # 16k mono PCM WAV
```

---

## Project status

Working, single-author hobby tool, used daily on the author's Hyprland desktop
(CachyOS). The voice bridge and VAD are battle-tested locally; the installer is
defensive (backups + waybar validation + revert) but every desktop is a little
different — read the diffs, keep the backups. Issues and PRs welcome.

## Credits

- Built around **[OpenClaw]** (the agent) and **[speaches]** (Whisper STT +
  Kokoro TTS sidecar).
- Status bar: **[waybar]**. Compositor: **[Hyprland]**.
- Default colours follow the **[Catppuccin] Mocha** palette.

> [Hyprland]: https://hyprland.org
> [Catppuccin]: https://github.com/catppuccin/catppuccin

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Steven Vallejo.
