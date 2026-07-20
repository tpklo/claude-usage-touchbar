# Security

This project reads an OAuth token out of your login keychain. That deserves a
precise account rather than a reassuring one, so this document describes what
the code actually does and points at the lines that do it. If any claim here
does not match the source, that is a bug — please open an issue.

## What is read, and by what

`~/bin/claude-touchbar.sh` runs:

```sh
security find-generic-password -s 'Claude Code-credentials' -a "$USER" -w
```

That is Apple's `/usr/bin/security` reading the keychain item **Claude Code
created when you signed in**. This project creates no keychain item of its own
and asks for no new access. On most machines `/usr/bin/security` is already a
trusted application on that item, so no dialog appears; if one does, it will
name `security`.

From the returned JSON only `claudeAiOauth.accessToken` and
`claudeAiOauth.expiresAt` are used. `refreshToken` is never read.

## Where the token goes

Exactly one place — the `Authorization` header of a single GET request:

```
GET https://api.anthropic.com/api/oauth/usage
```

Handling, in order:

1. The token lives in a shell variable for the duration of one request.
2. It reaches `curl` through **stdin** (`-H @-`), never as an argument — so it
   does not appear in `ps`, in your shell history, or in any process listing.
3. `unset tok` immediately after the request.
4. It is never written to a file, never logged, never printed, never copied to
   the clipboard, and never passed to a child process's environment.

There is no telemetry, no analytics, no crash reporting, and no second
network destination. `api.anthropic.com` is the only host this project
contacts at runtime. You can confirm that yourself:

```sh
grep -oE 'https?://[^ "]+' ~/bin/claude-touchbar.sh
```

## What the GUI process can do

Nothing, with respect to your credentials. `ClaudeTouchBar.app`:

- never links `Security.framework` and never calls any keychain API
- opens no sockets — it has no networking code at all
- spawns exactly one subprocess: `/bin/bash -lc ~/bin/claude-touchbar.sh --raw`
- parses six whitespace-separated numbers and strings from that output

The split exists so that the component with credential and network access is
around 100 lines of shell you can audit in a sitting, rather than a compiled
binary you have to take on trust.

## The disk-cache hazard, and why it is not present here

A prior tool that inspired this one used `NSURLSession.sharedSession` for the
same request. macOS caches responses for the shared session on disk, and the
cache retains request headers — so the full bearer token was written in plain
text to `~/Library/Caches/<bundle-id>/Cache.db-wal` with mode `0644`, readable
by any process running as that user, no prompt required. The application code
itself never wrote a file; the framework did it.

This project uses `curl` from a shell script, which has no such cache. The GUI
process performs no requests at all, so the failure mode cannot occur. If you
ever port the request into the app, use `ephemeralSessionConfiguration` and set
`URLCache` to `nil`.

That earlier tool's own SECURITY.md stated the token was "kept in memory only".
It was not. Verify claims like this against the code — including the ones on
this page.

## What is cached

`/tmp/.claude-usage-$UID`, mode `0600`, containing six whitespace-separated
values:

```
<5h%> <7d%> <resetMinutes> <scopedPct> <scopedName> <unixTimestamp>
```

Percentages and a timestamp. No token, no identifier, nothing about you.
Delete it whenever you like; it is rebuilt within a minute.

## Private API

The app calls `+[NSTouchBar presentSystemModalTouchBar:placement:systemTrayItemIdentifier:]`
and `DFRSystemModalShowsCloseBoxWhenFrontMost` from `DFRFoundation.framework`.
These are undocumented, and no public alternative exists — a Control Strip item
is a fixed narrow slot with no sizing API in either the public headers or the
private method table.

The call is guarded with `respondsToSelector:`; if a future macOS removes it,
the app logs and exits instead of crashing. This is also why the app can never
be distributed through the App Store.

No entitlements are requested. Ad-hoc signing is sufficient. No TCC permission
is required — not Accessibility, not Full Disk Access, nothing. **If macOS
prompts you for a permission while running this, that is a bug: file an issue.**

## Reporting

Open a GitHub issue. This is a personal project maintained on a best-effort
basis — if you need a guaranteed response window, this is not the right
dependency for you.
