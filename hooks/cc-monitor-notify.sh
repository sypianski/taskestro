#!/usr/bin/env bash
# Notification hook: records when a cc instance asks for user input.
# Monitor (expedi-rigardi) reads these files to show "awaiting-input since N min ago".
set -euo pipefail

cache_dir="${HOME}/.cache/cc-monitor"
mkdir -p "$cache_dir"

pane="${TMUX_PANE:-unknown}"
key="$(printf '%s' "$pane" | tr '/%' '__')"
input="$(cat || true)"
ts="$(date +%s)"

if command -v jq >/dev/null 2>&1 && [ -n "$input" ]; then
    printf '%s' "$input" \
        | jq --arg ts "$ts" --arg pane "$pane" \
            '. + {ts: ($ts|tonumber), pane: $pane}' \
        > "$cache_dir/${key}.json" 2>/dev/null \
        || printf '{"ts":%s,"pane":"%s","raw":%s}\n' "$ts" "$pane" "$(printf '%s' "$input" | jq -Rs . 2>/dev/null || echo '""')" > "$cache_dir/${key}.json"
else
    printf '{"ts":%s,"pane":"%s"}\n' "$ts" "$pane" > "$cache_dir/${key}.json"
fi

exit 0
