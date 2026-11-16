#!/bin/bash
# <xbar.title>test-gate</xbar.title>
# <xbar.desc>Machine-wide queue for heavy test runs: what is running and waiting.</xbar.desc>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
#
# SwiftBar runs plugins with a minimal PATH, so look in the default install dir too.
TG=$(command -v tg-status 2>/dev/null || echo "$HOME/.local/bin/tg-status")
if [ ! -x "$TG" ]; then
  echo "🧪?"
  echo "---"
  echo "tg-status not found: run install.sh from the test-gate repo"
  exit 0
fi
exec "$TG" --swiftbar
