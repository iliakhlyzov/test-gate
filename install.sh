#!/bin/bash
# install.sh - put test-gate commands on your PATH and (optionally) wire the
# Claude Code hook.
#
#   ./install.sh                 symlink commands into ~/.local/bin
#   ./install.sh --claude-hook   also add the PreToolUse hook to ~/.claude/settings.json
#   ./install.sh --uninstall     remove the symlinks (and the hook, if added)
#
# PREFIX=/some/bin ./install.sh  to use another directory.
set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
PREFIX=${PREFIX:-$HOME/.local/bin}
SETTINGS="$HOME/.claude/settings.json"
HOOK="$PREFIX/tg-claude-hook"
CMDS="tg-run tg-status tg-log tg-measure tg-claude-hook"

want_hook=0
uninstall=0
for a in "$@"; do
  case "$a" in
    --claude-hook) want_hook=1 ;;
    --uninstall) uninstall=1 ;;
    *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 64 ;;
  esac
done

# Apply a jq filter to settings.json. Writes through the file (keeps a
# symlinked settings.json working) and leaves it untouched if jq fails.
edit_settings() {
  local tmp="$SETTINGS.tmp.$$"
  if jq "$@" "$SETTINGS" >"$tmp"; then
    cp "$SETTINGS" "$SETTINGS.bak"
    cat "$tmp" >"$SETTINGS"
    rm -f "$tmp"
  else
    rm -f "$tmp"
    echo "! could not update $SETTINGS (jq failed); it was not changed" >&2
    return 1
  fi
}

remove_hook() {
  [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1 || return 0
  grep -q tg-claude-hook "$SETTINGS" || return 0
  edit_settings '.hooks.PreToolUse |= ((. // []) | map(.hooks |= ((. // []) | map(select((.command // "") | test("tg-claude-hook") | not)))) | map(select(.hooks | length > 0)))' \
    && echo "removed the hook from $SETTINGS (old version: $SETTINGS.bak)"
}

if [ $uninstall = 1 ]; then
  for c in $CMDS; do
    [ -L "$PREFIX/$c" ] && rm -f "$PREFIX/$c" && echo "removed $PREFIX/$c"
  done
  remove_hook
  exit 0
fi

mkdir -p "$PREFIX"
for c in $CMDS; do
  chmod +x "$ROOT/bin/$c"
  ln -sf "$ROOT/bin/$c" "$PREFIX/$c"
done
echo "linked $CMDS -> $PREFIX"

case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *)
    echo
    echo "! $PREFIX is not on your PATH. Add this line to ~/.zshrc and open a new terminal:"
    echo "    export PATH=\"$PREFIX:\$PATH\""
    ;;
esac

snippet=$(cat <<EOF
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "'$HOOK'" } ] }
    ]
  }
}
EOF
)

if [ $want_hook = 1 ]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo
    echo "! jq not found, add the hook to $SETTINGS by hand:"
    echo "$snippet"
  elif [ -f "$SETTINGS" ] && grep -q tg-claude-hook "$SETTINGS"; then
    echo "hook already present in $SETTINGS"
  else
    mkdir -p "$(dirname "$SETTINGS")"
    [ -f "$SETTINGS" ] || echo '{}' >"$SETTINGS"
    if edit_settings --arg cmd "'$HOOK'" '.hooks.PreToolUse = ((.hooks.PreToolUse // []) + [{"matcher": "Bash", "hooks": [{"type": "command", "command": $cmd}]}])'; then
      echo "added the hook to $SETTINGS (old version: $SETTINGS.bak). Restart Claude Code sessions to use it."
    else
      exit 1
    fi
  fi
else
  echo
  echo "Claude Code hook (optional): run './install.sh --claude-hook' or add to $SETTINGS:"
  echo "$snippet"
fi

echo
echo "Next: tell your agents about the queue, see docs/agents.md"
echo "Menu bar (optional): install SwiftBar and link $ROOT/swiftbar/test-gate.5s.sh into its plugin folder"
