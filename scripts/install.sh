#!/bin/bash
# Make Pretty Studio available to Tyler and to agents on this Mac:
#   ~/.local/bin/pretty          → bin/pretty on Master Storage (launcher)
#   ~/.claude/skills/pretty-studio/SKILL.md   (copied, so agents learn the tool even if the drive is out)
#   ~/.codex/skills/pretty-studio → the Claude skill (same pattern as mac-mini)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$HOME/.local/bin"
ln -sfn "$ROOT/bin/pretty" "$HOME/.local/bin/pretty"
chmod +x "$ROOT/bin/pretty" "$ROOT/scripts/"*.sh
mkdir -p "$HOME/.claude/skills/pretty-studio"
cp "$ROOT/docs/SKILL.md" "$HOME/.claude/skills/pretty-studio/SKILL.md"
if [ -d "$HOME/.codex/skills" ]; then
  ln -sfn "$HOME/.claude/skills/pretty-studio" "$HOME/.codex/skills/pretty-studio"
fi
echo "{\"ok\": true, \"launcher\": \"$HOME/.local/bin/pretty\", \"skill\": \"$HOME/.claude/skills/pretty-studio/SKILL.md\"}"
