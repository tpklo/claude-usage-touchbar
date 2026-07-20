#!/bin/bash
# Claude usage for the Touch Bar widget.
#
# Prints: "<5h%> <7d%> <resetMin> <ageSec> <state>"
#   state: ok      — fresh reading from the API
#          stale   — API unreachable, showing the last good numbers
#          expired — the OAuth token has expired; run `claude -p hi` to refresh
#          none    — never had a reading
#
# The caller MUST distinguish these: an expired token used to look identical to
# a healthy one, because the cache kept serving its last value forever.
#
# The token is read via /usr/bin/security (already on the keychain item's ACL,
# so nothing prompts), goes into a curl header over stdin — never argv, a file,
# or a log — and is unset immediately after.
set -uo pipefail

CACHE=/tmp/.claude-usage-$UID          # "5h 7d resetMin scopedPct scopedName epoch"
TTL=60
NODE=/Users/tongkunlong/.nvm/versions/node/v22.22.3/bin/node

read_cache() {                          # -> P5 P7 RESET SP SN STAMP
  [ -f "$CACHE" ] || return 1
  read -r P5 P7 RESET SP SN STAMP < "$CACHE" 2>/dev/null || :
  [ -n "${P5:-}" ]
}

P5=; P7=; RESET=-1; SP=-1; SN=-; STAMP=0
read_cache || :
AGE=$(( $(date +%s) - ${STAMP:-0} ))

state=ok
if [ "${STAMP:-0}" -eq 0 ] || [ "$AGE" -ge "$TTL" ]; then
  cred=$(security find-generic-password -s 'Claude Code-credentials' -a "$USER" -w 2>/dev/null)

  # Check expiry locally first: it tells us *why* we failed instead of guessing
  # from an HTTP code, and saves a round trip on a token that cannot work.
  expired=$(printf '%s' "$cred" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).claudeAiOauth.expiresAt<Date.now()?"1":"0")}catch{process.stdout.write("1")}})')

  if [ "$expired" = "1" ]; then
    state=expired
  else
    tok=$(printf '%s' "$cred" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).claudeAiOauth.accessToken)}catch{}})')
    unset cred

    # -w '%{http_code}' so a 401 is never silently parsed as "no data".
    resp=$(printf 'Authorization: Bearer %s' "$tok" | curl -sS --max-time 6 -H @- \
      -H 'Accept: application/json' -H 'anthropic-beta: oauth-2025-04-20' \
      -w '\n%{http_code}' https://api.anthropic.com/api/oauth/usage 2>/dev/null)
    unset tok

    code=$(printf '%s' "$resp" | tail -1)
    if [ "$code" = "401" ] || [ "$code" = "403" ]; then
      state=expired
    elif [ "$code" = "200" ]; then
      # SCALE: the API reports whole percentages (0-100) directly, and
      # limits[].percent confirms it. A previous version guessed the scale with
      # `v > 1 ? v : v*100`, which turned a real 1% into 100%. Never infer a
      # scale — read the field as the payload actually reports it.
      parsed=$(printf '%s' "$resp" | sed '$d' | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let j;try{j=JSON.parse(s)}catch{return};const pct=w=>(w&&typeof w.utilization==="number")?Math.round(w.utilization):-1;let p5=pct(j.five_hour),p7=pct(j.seven_day);let sp=-1,sn="-";for(const l of (j.limits||[])){if(typeof l.percent!=="number")continue;if(l.kind==="session")p5=Math.round(l.percent);else if(l.kind==="weekly_all")p7=Math.round(l.percent);else if(l.kind==="weekly_scoped"){sp=Math.round(l.percent);const nm=l.scope&&l.scope.model&&l.scope.model.display_name;if(nm)sn=nm.replace(/\s+/g,"")}}const t=j.five_hour&&j.five_hour.resets_at;const m=t?Math.max(0,Math.round((new Date(t)-new Date())/60000)):-1;process.stdout.write(`${p5} ${p7} ${m} ${sp} ${sn}`)})')
      case "$parsed" in
        ''|-1\ -1\ *) state=stale ;;
        *) printf '%s %s\n' "$parsed" "$(date +%s)" > "$CACHE"; chmod 600 "$CACHE"
           read_cache || :; AGE=0; state=ok ;;
      esac
    else
      state=stale                       # network/5xx — keep the last good numbers
    fi
  fi
fi

# A known cause beats "no data": report expired even with an empty cache,
# otherwise a first run on a dead token looks like a first run on a fresh one.
if [ -z "${P5:-}" ]; then
  [ "$state" = expired ] && { echo "0 0 -1 -1 expired"; exit 0; }
  echo "0 0 -1 -1 none"; exit 0
fi
[ "$state" = ok ] || AGE=$(( $(date +%s) - ${STAMP:-0} ))

case "${1:-}" in
  --raw) printf '%s %s %s %s %s %s %s\n' "$P5" "$P7" "$RESET" "$AGE" "$state" "${SP:--1}" "${SN:--}" ;;
  *)
     case "$state" in
       expired) printf 'token expired — run: claude -p hi   (last: 5h %s%%  7d %s%%)\n' "$P5" "$P7" ;;
       stale)   printf '5h %s%%  7d %s%%   (stale %dm)\n' "$P5" "$P7" $((AGE/60)) ;;
       *)       printf '5h %s%%  7d %s%%' "$P5" "$P7"
                [ "${SP:--1}" -gt 0 ] && printf '  %s %s%%' "${SN:--}" "$SP"
                printf '   reset %dh%02d\n' $((RESET/60)) $((RESET%60)) ;;
     esac ;;
esac
