#!/usr/bin/env bash
# Install `agy-loop` and the Claude Code skill from this checkout.
#
#   ./install.sh              symlink into ~/.local/bin and ~/.claude/skills
#   ./install.sh --force      replace anything already there (backs it up)
#
# Override destinations with AGY_LOOP_BIN_DIR and CLAUDE_SKILLS_DIR.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${AGY_LOOP_BIN_DIR:-$HOME/.local/bin}"
SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
SKILL_NAME="gemini-worker"
FORCE=0

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
  case "$arg" in
    --force|-f) FORCE=1 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "install.sh: unknown option: $arg" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- preflight -------------------------------------------------------------
command -v python3 >/dev/null 2>&1 || fail "python3 is required (3.9+)"
python3 - <<'PY' || fail "python3 must be 3.9 or newer"
import sys
sys.exit(0 if sys.version_info >= (3, 9) else 1)
PY

[ -f "$ROOT/bin/agy-loop" ] || fail "bin/agy-loop missing; run this from the repo checkout"
[ -f "$ROOT/skills/$SKILL_NAME/SKILL.md" ] || fail "skills/$SKILL_NAME/SKILL.md missing"

# --- link helper -----------------------------------------------------------
# link <source> <target>
link() {
  local src="$1" dst="$2"
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
      say "  up to date: $dst"
      return 0
    fi
    if [ "$FORCE" -eq 0 ]; then
      fail "$dst already exists (re-run with --force to replace it)"
    fi
    local backup="${dst}.bak-$(date +%Y%m%d%H%M%S)"
    mv "$dst" "$backup"
    say "  backed up existing entry to $backup"
  fi
  mkdir -p "$(dirname "$dst")"
  ln -sfn "$src" "$dst"
  say "  linked: $dst -> $src"
}

# --- install ---------------------------------------------------------------
say "Installing agy-loop from $ROOT"
link "$ROOT/bin/agy-loop" "$BIN_DIR/agy-loop"
link "$ROOT/skills/$SKILL_NAME" "$SKILLS_DIR/$SKILL_NAME"

# --- checks ----------------------------------------------------------------
say ""
if command -v agy >/dev/null 2>&1; then
  say "Antigravity CLI: $(command -v agy) ($(agy --version 2>/dev/null || echo 'version unknown'))"
else
  for cand in "$HOME/.local/bin/agy" "$HOME/.gemini/bin/agy"; do
    if [ -x "$cand" ]; then
      say "Antigravity CLI: $cand"
      break
    fi
  done
fi

if ! command -v agy >/dev/null 2>&1 &&
   [ ! -x "$HOME/.local/bin/agy" ] && [ ! -x "$HOME/.gemini/bin/agy" ]; then
  warn "Antigravity CLI (agy) not found. Install it before running a task:"
  warn "  curl -fsSL https://antigravity.google/cli/install.sh | bash"
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not on your PATH; add it or call $BIN_DIR/agy-loop directly" ;;
esac

say ""
say "Done. Try: agy-loop --version"
