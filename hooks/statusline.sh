#!/bin/sh
# Brow status line hook.
# Claude Code pipes session info (including your official 5h / 7d rate limits) to this
# script after each response. We save just the rate limits for the notch app, then print
# a short status line. Nothing leaves your Mac.
input=$(cat)
dir="$HOME/.claude/brow"

if printf '%s' "$input" | /usr/bin/jq -e '.rate_limits.five_hour != null' >/dev/null 2>&1; then
  printf '%s' "$input" \
    | /usr/bin/jq -c '{five_hour: .rate_limits.five_hour, seven_day: .rate_limits.seven_day, saved_at: now}' \
    > "$dir/usage.json.tmp" && mv "$dir/usage.json.tmp" "$dir/usage.json"
fi

# What Claude Code shows at the bottom of the terminal. Make this `printf ''` to show nothing.
printf '%s' "$input" | /usr/bin/jq -r '
  [ .model.display_name,
    (.rate_limits.five_hour.used_percentage | if . then "5h \(floor)%" else empty end),
    (.rate_limits.seven_day.used_percentage | if . then "7d \(floor)%" else empty end)
  ] | join(" · ")'
