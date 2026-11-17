#!/usr/bin/env bash
# Lane Renumber installer - macOS first (bash 3.2 compatible). Also works with --portable on any OS.
#
#   ./install_mac.sh                      install into ~/Library/Application Support/REAPER
#   ./install_mac.sh --portable DIR       install into a portable REAPER folder
#   ./install_mac.sh --no-register        do not touch reaper-kb.ini (add the actions by hand)
#   ./install_mac.sh --src DIR            folder containing the .lua files (default: ./Scripts/LaneRenumber, ., or ./dist)
#   ./install_mac.sh --package            build dist/LaneRenumber-<version>.zip (Scripts/ folder + this installer)
#   ./install_mac.sh --out DIR            with --package: write the zip into DIR instead of ./dist
#   ./install_mac.sh --uninstall          remove exactly what this script added
#
# Nothing here modifies your projects. reaper-kb.ini is only edited while REAPER is closed,
# and is backed up first.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
RES=""
SRC=""
DO_REGISTER=1
DO_UNINSTALL=0
DO_PACKAGE=0
OUT=""

FILES='LaneRenumber.lua LaneRenumber_Quick.lua'   # space separated; the first one carries @version
DIRNAME='LaneRenumber'
TITLE='Lane Renumber'

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
first_file() { set -- $FILES; printf '%s' "$1"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --portable)    [ $# -ge 2 ] || die "--portable needs a folder"; RES="$2"; shift 2 ;;
    --src)         [ $# -ge 2 ] || die "--src needs a folder"; SRC="$2"; shift 2 ;;
    --no-register) DO_REGISTER=0; shift ;;
    --uninstall)   DO_UNINSTALL=1; shift ;;
    --package)     DO_PACKAGE=1; shift ;;
    --out)         [ $# -ge 2 ] || die "--out needs a folder"; OUT="$2"; shift 2 ;;
    -h|--help)     sed -n '2,13p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

MAIN="$(first_file)"
locate_src() {
  if [ -n "$SRC" ]; then :
  elif [ -f "$HERE/Scripts/$DIRNAME/$MAIN" ]; then SRC="$HERE/Scripts/$DIRNAME"
  elif [ -f "$HERE/$MAIN" ];                  then SRC="$HERE"
  elif [ -f "$HERE/dist/$MAIN" ];             then SRC="$HERE/dist"
  else die "$MAIN not found (looked in ./Scripts/$DIRNAME, . and ./dist). Use --src <folder>."; fi
  for f in $FILES; do [ -f "$SRC/$f" ] || die "$SRC/$f not found"; done
}
version_of() { sed -n 's/^-- @version[[:space:]]*//p' "$1" | head -n 1; }

# ---- --package ---------------------------------------------------------------------------------
if [ "$DO_PACKAGE" = 1 ]; then
  command -v zip >/dev/null 2>&1 || die "--package needs the 'zip' command"
  locate_src
  VERSION="$(version_of "$SRC/$MAIN")"
  PKG="$DIRNAME-${VERSION:-dev}"
  OUTDIR="${OUT:-$HERE/dist}"; mkdir -p "$OUTDIR"; OUTDIR="$(cd "$OUTDIR" && pwd)"
  ZIP="$OUTDIR/$PKG.zip"
  STAGE="$(mktemp -d "${TMPDIR:-/tmp}/pkg.XXXXXX")"
  trap 'rm -rf "$STAGE"' EXIT
  mkdir -p "$STAGE/$PKG/Scripts/$DIRNAME"
  for f in $FILES; do cp "$SRC/$f" "$STAGE/$PKG/Scripts/$DIRNAME/$f"; done
  cp "$HERE/$(basename "$0")" "$STAGE/$PKG/install_mac.sh"; chmod 755 "$STAGE/$PKG/install_mac.sh"
  for f in README.md CHANGELOG.md LICENSE; do [ -f "$HERE/$f" ] && cp "$HERE/$f" "$STAGE/$PKG/$f"; done
  # same input -> same zip: fixed timestamps, sorted entries, no extra attributes
  find "$STAGE" -exec touch -t 202001010000 {} +
  rm -f "$ZIP"
  ( cd "$STAGE" && find "$PKG" | LC_ALL=C sort | zip -X -q "$ZIP" -@ )
  say "Built $ZIP"
  exit 0
fi

# ---- REAPER's resource folder ------------------------------------------------------------------
if [ -z "$RES" ]; then
  case "$(uname -s)" in
    Darwin) RES="$HOME/Library/Application Support/REAPER" ;;
    *)      RES="$HOME/.config/REAPER" ;;
  esac
fi
[ -d "$RES" ] || die "REAPER resource folder not found: $RES
Start REAPER once so it creates it, or pass --portable <folder>."

SCRIPT_DIR="$RES/Scripts/$DIRNAME"
KB="$RES/reaper-kb.ini"

reaper_running() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x REAPER >/dev/null 2>&1 || pgrep -x reaper >/dev/null 2>&1
  else
    return 0     # cannot tell: be safe and treat as running
  fi
}
sha1() {
  if command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 1 | cut -d' ' -f1
  else printf '%s' "$1" | sha1sum | cut -d' ' -f1; fi
}
backup_kb() { [ -f "$KB" ] && cp "$KB" "$KB.lane-renumber-backup-$(date +%Y%m%d-%H%M%S)"; return 0; }
# remove every reaper-kb.ini line that registers one of our scripts
kb_remove() {
  [ -f "$KB" ] || return 0
  grep -qF -e "$SCRIPT_DIR/" "$KB" 2>/dev/null || return 0
  backup_kb
  grep -vF -e "$SCRIPT_DIR/" "$KB" > "$KB.tmp.$$" || true
  mv "$KB.tmp.$$" "$KB"
}

# ---- uninstall ---------------------------------------------------------------------------------
if [ "$DO_UNINSTALL" = 1 ]; then
  say "Uninstalling $TITLE from: $RES"
  if reaper_running; then
    warn "REAPER seems to be running. Close it first so reaper-kb.ini can be cleaned; skipping that part."
  else
    kb_remove; say "  removed action registrations (if they existed)"
  fi
  for f in $FILES; do rm -f "$SCRIPT_DIR/$f"; done
  rmdir "$SCRIPT_DIR" 2>/dev/null || true
  say "Done. Your projects are untouched."
  exit 0
fi

# ---- install -----------------------------------------------------------------------------------
locate_src
VERSION="$(version_of "$SRC/$MAIN")"
say "Installing $TITLE ${VERSION:-?} into: $RES"
mkdir -p "$SCRIPT_DIR"
for f in $FILES; do cp "$SRC/$f" "$SCRIPT_DIR/$f"; say "  script  -> $SCRIPT_DIR/$f"; done

if [ "$(uname -s)" = "Darwin" ] && command -v xattr >/dev/null 2>&1; then
  xattr -dr com.apple.quarantine "$SCRIPT_DIR" 2>/dev/null || true
  say "  removed download quarantine flag"
fi

if ls "$RES/UserPlugins" 2>/dev/null | grep -i 'imgui' >/dev/null 2>&1; then
  say "  ReaImGui: found"
else
  warn "ReaImGui was not found in $RES/UserPlugins."
  say  "  The window needs it (the quick action does not): Extensions > ReaPack > Browse packages > 'ReaImGui'."
fi

REGISTERED=0
if [ "$DO_REGISTER" = 1 ]; then
  if reaper_running; then
    warn "REAPER seems to be running - not editing reaper-kb.ini."
  elif [ ! -f "$KB" ]; then
    warn "$KB does not exist yet (start and close REAPER once)."
  else
    kb_remove
    backup_kb
    for f in $FILES; do
      ID="RS$(sha1 "$SCRIPT_DIR/$f")"
      printf 'SCR 4 0 %s "Script: %s" "%s"\n' "$ID" "$f" "$SCRIPT_DIR/$f" >> "$KB"
    done
    REGISTERED=1
    say "  actions -> registered (backup of reaper-kb.ini kept next to it)"
  fi
fi

say ""
if [ "$REGISTERED" = 1 ]; then
  say "Next: start REAPER, Actions > Show action list, search 'LaneRenumber', run 'Script: $MAIN'."
else
  say "Next: in REAPER, Actions > Show action list > New action > Load ReaScript..., choose the files in"
  say "      $SCRIPT_DIR"
fi
say "Uninstall any time with: $0 --uninstall"
