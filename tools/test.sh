#!/bin/bash
# Exercises the JSON parser inside claude-touchbar.sh against fixed payloads.
#
# The parser is the part most likely to break silently: a wrong scale or a
# swallowed field still prints something that looks like a reading. These cases
# are the ones that actually went wrong, or nearly did.
#
# No network, no keychain, no Claude.app — safe to run anywhere, including CI.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PY=/usr/bin/python3
[ -x "$PY" ] || PY=$(command -v python3) || { echo "no python3"; exit 1; }

# Pull the parser out of the script itself so the test exercises the shipped
# code rather than a copy that can drift. Anchored on `parsed=$(` because the
# script has more than one python invocation.
SRC=$(awk '/parsed=\$\(/{f=1;next} f{ if(/^print\(f/){sub(/\x27\)$/,"");print;exit} print }' claude-touchbar.sh)
[ -n "$SRC" ] || { echo "FAIL: could not extract the parser from claude-touchbar.sh"; exit 1; }

pass=0 fail=0
check() { # name, payload, expected ("*" matches any single field)
  local got; got=$(printf '%s' "$2" | "$PY" -c "$SRC" 2>/dev/null)
  local ok=1 i
  read -ra g <<< "$got"; read -ra w <<< "$3"
  [ "${#g[@]}" = "${#w[@]}" ] || ok=0
  for i in "${!w[@]}"; do
    [ "${w[$i]}" = "*" ] && continue
    [ "${g[$i]:-}" = "${w[$i]}" ] || ok=0
  done
  if [ "$ok" = 1 ]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s\n         got      [%s]\n         expected [%s]\n' "$1" "$got" "$3"; fi
}

echo "parser:"

# The API reports whole percentages. A previous version guessed the scale with
# `v > 1 ? v : v*100`, turning a real 1% into a displayed 100%.
check "reads utilization as-is" \
  '{"five_hour":{"utilization":37},"seven_day":{"utilization":8}}' \
  "37 8 -1 -1 -"
check "1% stays 1%" \
  '{"five_hour":{"utilization":1},"seven_day":{"utilization":1}}' \
  "1 1 -1 -1 -"

# limits[] is authoritative when present and must win over the top-level windows.
check "limits[] overrides" \
  '{"five_hour":{"utilization":10},"limits":[{"kind":"session","percent":91},{"kind":"weekly_all","percent":44}]}' \
  "91 44 -1 -1 -"
check "weekly_scoped + model name" \
  '{"limits":[{"kind":"weekly_scoped","percent":12,"scope":{"model":{"display_name":"Claude Fable 5"}}}]}' \
  "-1 -1 -1 12 ClaudeFable5"
check "scoped without a name" \
  '{"limits":[{"kind":"weekly_scoped","percent":12}]}' \
  "-1 -1 -1 12 -"

# Anything non-numeric must fall back to -1 rather than reaching the widget as
# text: the caller does integer arithmetic on these fields.
check "percent as string is ignored" \
  '{"limits":[{"kind":"session","percent":"91"}]}' \
  "-1 -1 -1 -1 -"
check "null utilization" \
  '{"five_hour":{"utilization":null},"seven_day":{}}' \
  "-1 -1 -1 -1 -"
check "empty object" '{}' "-1 -1 -1 -1 -"

# resets_at feeds $((RESET/60)) in the caller. The old node parser emitted NaN
# here, which made that arithmetic fail.
check "unparseable resets_at -> -1" \
  '{"five_hour":{"utilization":5,"resets_at":"garbage"}}' \
  "5 -1 -1 -1 -"
check "valid resets_at -> a number" \
  '{"five_hour":{"utilization":5,"resets_at":"2030-01-01T00:00:00Z"}}' \
  "5 -1 * -1 -"

# Malformed input must produce nothing at all, which the caller treats as stale
# — printing a partial line would be read as a live measurement.
got=$(printf 'not json' | "$PY" -c "$SRC" 2>/dev/null)
if [ -z "$got" ]; then pass=$((pass+1)); echo "  ok    malformed JSON prints nothing"
else fail=$((fail+1)); echo "  FAIL  malformed JSON printed [$got]"; fi

echo
echo "shell:"
if command -v shellcheck >/dev/null; then
  if shellcheck -S warning claude-touchbar.sh tools/test.sh; then
    pass=$((pass+1)); echo "  ok    shellcheck"
  else fail=$((fail+1)); echo "  FAIL  shellcheck"; fi
else
  echo "  --    shellcheck not installed, skipped"
fi

if "$PY" -m py_compile tools/extract-assets.py 2>/dev/null; then
  pass=$((pass+1)); echo "  ok    extract-assets.py compiles"
else fail=$((fail+1)); echo "  FAIL  extract-assets.py does not compile"; fi

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
