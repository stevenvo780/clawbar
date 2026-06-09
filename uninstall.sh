#!/usr/bin/env bash
# ===========================================================================
# clawbar — uninstaller. Restores the most recent clawbar backups and removes
# the installed scripts. It does NOT delete your clawbar.env (your settings).
#
# For each touched file it restores the newest *.bak-clawbar-* sibling if one
# exists; otherwise it surgically strips the clawbar blocks it appended.
# ===========================================================================
set -uo pipefail

BIN_DIR="${CLAWBAR_BIN_DIR:-$HOME/.local/bin}"
WAYBAR_DIR="${CLAWBAR_WAYBAR_DIR:-$HOME/.config/waybar}"
WAYBAR_CONFIG="${CLAWBAR_WAYBAR_CONFIG:-$WAYBAR_DIR/config.jsonc}"
WAYBAR_STYLE="${CLAWBAR_WAYBAR_STYLE:-$WAYBAR_DIR/style.css}"
HYPR_CONF="${CLAWBAR_HYPR_CONF:-$HOME/.config/hypr/hyprland.conf}"
CLAW_TALK_LEGACY="${CLAWBAR_CLAW_TALK_LEGACY:-/datos/claw-voice/claw-talk}"

c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_reset=$'\033[0m'
ok()   { printf '%s[ok]%s   %s\n' "$c_green"  "$c_reset" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$c_yellow" "$c_reset" "$*"; }

newest_backup() {  # echo newest *.bak-clawbar-* for $1, if any
  local base="$1"
  ls -1t "$base".bak-clawbar-* 2>/dev/null | head -1
}

restore_or_strip() {  # $1 file, $2 marker-grep to strip if no backup
  local f="$1" marker="$2" bak
  [ -f "$f" ] || { warn "missing, skip: $f"; return; }
  bak="$(newest_backup "$f")"
  if [ -n "$bak" ] && [ -f "$bak" ]; then
    cp -p "$bak" "$f"
    ok "restored $f  <-  $(basename "$bak")"
  else
    warn "no backup for $f — leaving as-is (manual cleanup of '$marker' may be needed)"
  fi
}

echo "=== clawbar uninstall ==="

# 1) remove installed bins (restore their backups if present)
for f in claw-talk clawbar-vad.py clawbar-status; do
  if [ -f "$BIN_DIR/$f" ]; then
    bak="$(newest_backup "$BIN_DIR/$f")"
    if [ -n "$bak" ]; then cp -p "$bak" "$BIN_DIR/$f"; ok "restored $BIN_DIR/$f"; else rm -f "$BIN_DIR/$f"; ok "removed $BIN_DIR/$f"; fi
  fi
done

# 1b) legacy claw-talk: restore its backup if we deployed over one
if [ -f "$CLAW_TALK_LEGACY" ]; then
  bak="$(newest_backup "$CLAW_TALK_LEGACY")"
  if [ -n "$bak" ]; then cp -p "$bak" "$CLAW_TALK_LEGACY"; ok "restored $CLAW_TALK_LEGACY"; else warn "no backup for $CLAW_TALK_LEGACY — left in place"; fi
fi

# 2) waybar config + modules + style: restore newest backups
restore_or_strip "$WAYBAR_CONFIG" "custom/claw"
[ -f "$WAYBAR_DIR/modules.jsonc" ] && restore_or_strip "$WAYBAR_DIR/modules.jsonc" "custom/claw"
restore_or_strip "$WAYBAR_STYLE"  "custom-claw"

# 3) hyprland keybind
restore_or_strip "$HYPR_CONF" "clawbar"

# 4) reload
pgrep -x waybar >/dev/null 2>&1 && { pkill -SIGUSR2 waybar 2>/dev/null; ok "waybar reloaded"; }
command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1 || true

echo
ok "clawbar uninstalled. Your config (clawbar.env) was kept."
echo "  Backups (*.bak-clawbar-*) were left on disk; remove them when satisfied."
