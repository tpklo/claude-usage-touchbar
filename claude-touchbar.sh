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

umask 077
# Never read the legacy shared /tmp cache. Keep usage data in a private
# directory directly under the current user's home.
TTL=60

# /usr/bin/python3 ships with the Command Line Tools, which this project already
# requires to build — so there is no runtime dependency to install. An earlier
# version pointed at a hard-coded nvm path, which worked on exactly one machine.
PY=/usr/bin/python3
[ -x "$PY" ] || PY=$(command -v python3) || {
  echo "0 0 -1 -1 none"; exit 0; }

# Open paths relative to verified directory descriptors. O_NOFOLLOW rejects
# symlinks; O_NONBLOCK prevents a planted FIFO from hanging the poller. This
# helper also normalizes *every* number before Bash can use it in arithmetic.
cache_io() {
  "$PY" - "$1" "${2:-}" <<'PY_CACHE'
import os, re, stat, sys, time, uuid

def record(text):
    fields = text.split()
    if len(fields) != 6:
        raise ValueError("invalid field count")
    values = []
    for value, low, high in zip(fields[:4], [-1, -1, -1, -1], [100, 100, 525600, 100]):
        if not re.fullmatch(r"-?[0-9]{1,10}", value):
            raise ValueError("invalid number")
        value = int(value, 10)
        if not low <= value <= high:
            raise ValueError("number out of range")
        values.append(str(value))
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", fields[4]):
        raise ValueError("invalid model name")
    if not re.fullmatch(r"[0-9]{1,10}", fields[5]):
        raise ValueError("invalid timestamp")
    stamp = int(fields[5], 10)
    if not 0 < stamp <= int(time.time()) + 5:
        raise ValueError("timestamp out of range")
    return " ".join(values + [fields[4], str(stamp)])

try:
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    home = os.open(os.path.expanduser("~"), flags)
    info = os.fstat(home)
    if info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise ValueError("unsafe home directory")
    try:
        os.mkdir(".claude-usage-touchbar", 0o700, dir_fd=home)
    except FileExistsError:
        pass
    directory = os.open(".claude-usage-touchbar", flags, dir_fd=home)
    info = os.fstat(directory)
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise ValueError("unsafe cache directory")
    if sys.argv[1] == "read":
        fd = os.open("usage", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1
                or info.st_size > 1024):
            raise ValueError("unsafe cache file")
        with os.fdopen(fd) as stream:
            result = record(stream.read(1025))
    else:
        result = record(sys.argv[2])
        name = ".usage-" + uuid.uuid4().hex
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=directory)
        try:
            with os.fdopen(fd, "w") as stream:
                stream.write(result + "\n")
            os.replace(name, "usage", src_dir_fd=directory, dst_dir_fd=directory)
        finally:
            try:
                os.unlink(name, dir_fd=directory)
            except FileNotFoundError:
                pass
    print(result)
except (OSError, ValueError, UnicodeError):
    sys.exit(1)
PY_CACHE
}

read_cache() {                          # -> P5 P7 RESET SP SN STAMP
  local validated
  validated=$(cache_io read) || return 1
  read -r P5 P7 RESET SP SN STAMP <<< "$validated"
}

P5=; P7=; RESET=-1; SP=-1; SN=-; STAMP=0
read_cache || :
AGE=$(( $(date +%s) - ${STAMP:-0} ))

state=ok
if [ "${STAMP:-0}" -eq 0 ] || [ "$AGE" -ge "$TTL" ]; then
  cred=$(security find-generic-password -s 'Claude Code-credentials' -a "$USER" -w 2>/dev/null)

  # Check expiry locally first: it tells us *why* we failed instead of guessing
  # from an HTTP code, and saves a round trip on a token that cannot work.
  expired=$(printf '%s' "$cred" | "$PY" -c 'import json,sys,time
try: print("1" if json.load(sys.stdin)["claudeAiOauth"]["expiresAt"] < time.time()*1000 else "0")
except Exception: print("1")')

  if [ "$expired" = "1" ]; then
    state=expired
  else
    tok=$(printf '%s' "$cred" | "$PY" -c 'import json,sys
try: sys.stdout.write(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])
except Exception: pass')
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
      parsed=$(printf '%s' "$resp" | sed '$d' | "$PY" -c '
import json, sys, re, datetime
try: j = json.load(sys.stdin)
except Exception: sys.exit(0)

def pct(w):
    v = (w or {}).get("utilization")
    return round(v) if isinstance(v, (int, float)) else -1

p5, p7, sp, sn = pct(j.get("five_hour")), pct(j.get("seven_day")), -1, "-"

for l in j.get("limits") or []:
    v = l.get("percent")
    if not isinstance(v, (int, float)):
        continue
    k = l.get("kind")
    if k == "session":       p5 = round(v)
    elif k == "weekly_all":  p7 = round(v)
    elif k == "weekly_scoped":
        sp = round(v)
        nm = ((l.get("scope") or {}).get("model") or {}).get("display_name")
        if isinstance(nm, str): sn = re.sub(r"[^A-Za-z0-9_.-]", "", nm)[:64] or "-"

m = -1
t = (j.get("five_hour") or {}).get("resets_at")
if t:
    try:
        # fromisoformat only learned to accept a trailing Z in 3.11.
        d = datetime.datetime.fromisoformat(t.replace("Z", "+00:00"))
        m = max(0, round((d - datetime.datetime.now(d.tzinfo)).total_seconds() / 60))
    except Exception:
        pass

print(f"{p5} {p7} {m} {sp} {sn}")')
      case "$parsed" in
        ''|-1\ -1\ *) state=stale ;;
        *) if validated=$(cache_io write "$parsed $(date +%s)"); then
             read -r P5 P7 RESET SP SN STAMP <<< "$validated"
             AGE=0; state=ok
           else
             state=stale
           fi ;;
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

