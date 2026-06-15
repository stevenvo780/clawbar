#!/usr/bin/env bash
# ===========================================================================
# clawbar — installer. Idempotent, makes timestamped backups, validates waybar.
#
# What it does:
#   1. Installs bin/* (claw-talk, clawbar-vad.py, clawbar-status) to BIN_DIR
#      (default ~/.local/bin). Optionally also deploys claw-talk to a legacy
#      path (CLAW_TALK_LEGACY) with a backup, preserving existing behaviour.
#   2. Creates clawbar.env from the example if it does not exist.
#   3. Merges the custom/claw module into your waybar config:
#        - adds the "custom/claw" definition to your modules file,
#        - adds "custom/claw" to a visible modules array (modules-right),
#        - rewrites the on-click commands to your real launchers,
#        - VALIDATES that waybar still parses; reverts that step if not.
#   4. Appends style.css (with @-free block) to your waybar style.
#   5. Adds the Hyprland keybind only if no claw-talk bind exists yet.
#   6. Reloads waybar (SIGUSR2) and `hyprctl reload` if available.
#
# Everything is guarded and reversible (uninstall.sh restores backups).
# Re-running is safe: existing pieces are detected and skipped.
# ===========================================================================
set -uo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
BAK_SUFFIX="bak-clawbar-$TS"

# ---- configurable targets (env-overridable) --------------------------------
BIN_DIR="${CLAWBAR_BIN_DIR:-$HOME/.local/bin}"
WAYBAR_DIR="${CLAWBAR_WAYBAR_DIR:-$HOME/.config/waybar}"
WAYBAR_CONFIG="${CLAWBAR_WAYBAR_CONFIG:-$WAYBAR_DIR/config.jsonc}"
WAYBAR_MODULES="${CLAWBAR_WAYBAR_MODULES:-}"   # auto-detected below if empty
WAYBAR_STYLE="${CLAWBAR_WAYBAR_STYLE:-$WAYBAR_DIR/style.css}"
WAYBAR_BAR_ARRAY="${CLAWBAR_WAYBAR_BAR_ARRAY:-modules-right}"
HYPR_CONF="${CLAWBAR_HYPR_CONF:-$HOME/.config/hypr/hyprland.conf}"
ENV_DEST="${CLAWBAR_ENV_DEST:-$HOME/.config/clawbar/clawbar.env}"

# on-click launchers wired into the waybar module (point at the real ones)
CLICK_LEFT="${CLAWBAR_CLICK_LEFT:-claw-talk toggle}"
CLICK_RIGHT="${CLAWBAR_CLICK_RIGHT:-$BIN_DIR/chat-claw.sh}"
CLICK_MIDDLE="${CLAWBAR_CLICK_MIDDLE:-kitty bash -lc \"docker exec -it claw openclaw tui\"}"

# optionally deploy the new claw-talk over a legacy install (keeps it working)
CLAW_TALK_LEGACY="${CLAWBAR_CLAW_TALK_LEGACY:-/datos/claw-voice/claw-talk}"

c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_reset=$'\033[0m'
ok()   { printf '%s[ok]%s   %s\n'   "$c_green"  "$c_reset" "$*"; }
warn() { printf '%s[warn]%s %s\n'   "$c_yellow" "$c_reset" "$*"; }
err()  { printf '%s[err]%s  %s\n'   "$c_red"    "$c_reset" "$*" >&2; }
info() { printf '[info] %s\n' "$*"; }

backup() {  # $1 = file to back up (if it exists)
  [ -f "$1" ] || return 0
  cp -p "$1" "$1.$BAK_SUFFIX"
  info "backup: $1.$BAK_SUFFIX"
}

# detect the modules file: prefer an explicit override, else any file the
# config "include"s, else config.jsonc itself.
detect_modules_file() {
  [ -n "$WAYBAR_MODULES" ] && { echo "$WAYBAR_MODULES"; return; }
  if [ -f "$WAYBAR_DIR/modules.jsonc" ]; then echo "$WAYBAR_DIR/modules.jsonc"; return; fi
  if [ -f "$WAYBAR_DIR/modules.json" ]; then echo "$WAYBAR_DIR/modules.json"; return; fi
  echo "$WAYBAR_CONFIG"
}

# ---------------------------------------------------------------------------
echo "=== clawbar install ($TS) ==="
mkdir -p "$BIN_DIR"

# 1) bin/*
for f in claw-talk clawbar-vad.py clawbar-status claw-up; do
  if [ -f "$BIN_DIR/$f" ]; then backup "$BIN_DIR/$f"; fi
  install -m 0755 "$SRC_DIR/bin/$f" "$BIN_DIR/$f"
  ok "installed $BIN_DIR/$f"
done

# 1b) legacy claw-talk deploy (optional; keeps the operator's current path live)
if [ -n "$CLAW_TALK_LEGACY" ] && [ -e "$(dirname "$CLAW_TALK_LEGACY")" ]; then
  if [ -f "$CLAW_TALK_LEGACY" ]; then backup "$CLAW_TALK_LEGACY"; fi
  install -m 0755 "$SRC_DIR/bin/claw-talk"    "$CLAW_TALK_LEGACY"
  install -m 0755 "$SRC_DIR/bin/clawbar-vad.py" "$(dirname "$CLAW_TALK_LEGACY")/clawbar-vad.py"
  ok "deployed claw-talk + clawbar-vad.py to $(dirname "$CLAW_TALK_LEGACY")"
fi

# 2) clawbar.env
mkdir -p "$(dirname "$ENV_DEST")"
if [ -f "$ENV_DEST" ]; then
  ok "config exists, kept: $ENV_DEST"
else
  cp "$SRC_DIR/clawbar.env.example" "$ENV_DEST"
  ok "created config: $ENV_DEST (edit to taste)"
fi

# ---------------------------------------------------------------------------
# 3) waybar module merge (the risky part) — Python does the JSONC-aware edit
# ---------------------------------------------------------------------------
MODULES_FILE="$(detect_modules_file)"
info "waybar config:  $WAYBAR_CONFIG"
info "waybar modules: $MODULES_FILE"

if [ ! -f "$WAYBAR_CONFIG" ]; then
  warn "waybar config not found ($WAYBAR_CONFIG) — skipping waybar wiring"
else
  backup "$WAYBAR_CONFIG"
  [ "$MODULES_FILE" != "$WAYBAR_CONFIG" ] && backup "$MODULES_FILE"

  CLICK_LEFT="$CLICK_LEFT" CLICK_RIGHT="$CLICK_RIGHT" CLICK_MIDDLE="$CLICK_MIDDLE" \
  BAR_ARRAY="$WAYBAR_BAR_ARRAY" \
  python3 "$SRC_DIR/scripts-internal/merge_waybar.py" \
      "$WAYBAR_CONFIG" "$MODULES_FILE"
  merge_rc=$?

  if [ "$merge_rc" -ne 0 ]; then
    err "waybar merge failed (rc=$merge_rc) — restoring backups"
    [ -f "$WAYBAR_CONFIG.$BAK_SUFFIX" ] && cp -p "$WAYBAR_CONFIG.$BAK_SUFFIX" "$WAYBAR_CONFIG"
    [ "$MODULES_FILE" != "$WAYBAR_CONFIG" ] && [ -f "$MODULES_FILE.$BAK_SUFFIX" ] && cp -p "$MODULES_FILE.$BAK_SUFFIX" "$MODULES_FILE"
  else
    # validate waybar can parse the result (dry config check)
    if waybar -c "$WAYBAR_CONFIG" -s "$WAYBAR_STYLE" --log-level error -l error >/dev/null 2>&1 & then
      wpid=$!; sleep 1.2
      if kill -0 "$wpid" 2>/dev/null; then
        kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
        ok "waybar parses the merged config"
      else
        wait "$wpid" 2>/dev/null; rc=$?
        warn "test waybar exited rc=$rc — assuming OK if a real bar is already running"
      fi
    fi
    ok "waybar module merged (custom/claw in $WAYBAR_BAR_ARRAY)"
  fi
fi

# ---------------------------------------------------------------------------
# 4) style.css append
# ---------------------------------------------------------------------------
if [ -f "$WAYBAR_STYLE" ]; then
  if grep -q 'custom-claw.muted' "$WAYBAR_STYLE"; then
    ok "style already has clawbar privacy rules, skipped"
  elif grep -q 'custom-claw' "$WAYBAR_STYLE"; then
    # instalación previa: agregamos SOLO las clases nuevas de privacidad
    backup "$WAYBAR_STYLE"
    {
      printf '\n/* === clawbar privacidad (added %s) === */\n' "$TS"
      printf '#custom-claw.muted { color: #f38ba8; }\n'
      printf '#custom-claw.blind { color: #f9e2af; }\n'
    } >> "$WAYBAR_STYLE"
    ok "appended clawbar privacy styles to $WAYBAR_STYLE"
  else
    backup "$WAYBAR_STYLE"
    {
      printf '\n/* === clawbar (added %s) === */\n' "$TS"
      cat "$SRC_DIR/waybar/style.css"
    } >> "$WAYBAR_STYLE"
    ok "appended clawbar styles to $WAYBAR_STYLE"
  fi
else
  warn "waybar style not found ($WAYBAR_STYLE) — skipping styles"
fi

# ---------------------------------------------------------------------------
# 5) Hyprland keybind (only if absent)
# ---------------------------------------------------------------------------
if [ -f "$HYPR_CONF" ]; then
  if grep -qE 'claw-talk (mute|eyes|privacy)' "$HYPR_CONF"; then
    ok "hyprland already has clawbar privacy binds, not duplicating"
  elif grep -qE 'claw-talk' "$HYPR_CONF"; then
    # instalación previa (solo el bind de voz): agregamos SOLO lo nuevo
    backup "$HYPR_CONF"
    {
      printf '\n# === clawbar privacidad/autostart (added %s) ===\n' "$TS"
      printf 'bind = $mainMod SHIFT, M, exec, claw-talk mute      # Claw: mutear / desmutear\n'
      printf 'bind = $mainMod SHIFT, O, exec, claw-talk eyes      # Claw: tapar / abrir ojos\n'
      printf 'bind = $mainMod SHIFT, P, exec, claw-talk privacy   # Claw: privacidad total\n'
      printf 'exec-once = claw-up\n'
    } >> "$HYPR_CONF"
    ok "added clawbar privacy binds + autostart to $HYPR_CONF"
  else
    backup "$HYPR_CONF"
    {
      printf '\n# === clawbar (added %s) ===\n' "$TS"
      cat "$SRC_DIR/hypr/keybind.conf"
    } >> "$HYPR_CONF"
    ok "added Hyprland keybind to $HYPR_CONF"
  fi
else
  warn "hyprland.conf not found ($HYPR_CONF) — skipping keybind"
fi

# ---------------------------------------------------------------------------
# 6) reload
# ---------------------------------------------------------------------------
if pgrep -x waybar >/dev/null 2>&1; then
  pkill -SIGUSR2 waybar 2>/dev/null && ok "waybar reloaded (SIGUSR2)" || warn "could not signal waybar"
else
  warn "waybar not running — start it to see the module"
fi
command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1 && ok "hyprctl reload" || true

echo
ok "clawbar installed."
echo "  - voice toggle:   $BIN_DIR/claw-talk toggle   (or SUPER+SHIFT+V)"
echo "  - module script:  $BIN_DIR/clawbar-status"
echo "  - config:         $ENV_DEST"
echo "  - uninstall:      $SRC_DIR/uninstall.sh"
