#!/bin/bash
# Claude Code status-line command that saves the documented `rate_limits` field
# to ~/.claude/usage-snapshot.json for the menu bar app, then prints a short status line.
#
# settings.json:
#   "statusLine": { "type": "command", "command": "~/.claude/statusline-snapshot.sh" }
#
# To keep an existing status line, set NEXT_STATUSLINE to its command; it gets the same JSON.

input=$(cat)
out="$HOME/.claude/usage-snapshot.json"

if printf '%s' "$input" | jq -e '.rate_limits | type == "object" and length > 0' >/dev/null 2>&1; then
  tmp=$(mktemp "$out.XXXXXX") &&
    printf '%s' "$input" | jq -c '{captured_at: (now | floor), rate_limits}' >"$tmp" &&
    mv -f "$tmp" "$out"
fi

if [ -n "$NEXT_STATUSLINE" ]; then
  printf '%s' "$input" | eval "$NEXT_STATUSLINE"
else
  printf '%s' "$input" | jq -r '
    [ .model.display_name // empty,
      (.rate_limits.five_hour.used_percentage // empty | "5h \(floor)%"),
      (.rate_limits.seven_day.used_percentage // empty | "7d \(floor)%") ] | join("  ·  ")'
fi
