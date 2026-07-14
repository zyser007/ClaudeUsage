# ClaudeUsage

A macOS menu bar app showing your Claude Code usage — quota percentages and what
today's work would have cost. Reads everything from local files; no API key.

![menu bar: icon + session percentage](Resources/MenuIcon.png)

## What it shows

- **Session (5hr)**, **Weekly (7 day)** and per-model quota bars, with reset times
- **Today's cost** — the headline number, computed from local transcripts
- Token breakdown (output / input / cache write / cache read)
- Per-project split by **share of cost**
- A 7-day cost sparkline, with the exact figure on hover

The menu bar itself carries the session percentage, so the number you glance at
most never needs a click.

## Requirements

macOS 14+, Swift 6 toolchain, and Claude Code installed.

## Build

```sh
./make-signing-cert.sh   # once — see "Signing" below
./build.sh
open ClaudeUsage.app
```

`build.sh` works without the certificate too; it just falls back to ad-hoc
signing and says so.

## Where the numbers come from

Two independent sources, on two different clocks — the UI labels which is which,
because conflating them is misleading:

| | Source | Freshness |
|---|---|---|
| Quota % | `~/.claude.json` → `cachedUsageUtilization` | measured snapshot, refreshed ~every 6 min |
| Cost / tokens | `~/.claude/projects/**/*.jsonl` | rescanned every 30s, incrementally |

### The quota snapshot is not live

`~/.claude.json` holds a *cached* measurement. Ordinary Claude Code API traffic
does **not** update it — measured, not assumed. The only thing that does is the
`/usage` command, so the app runs `claude -p "/usage"` itself when the snapshot
is older than 6 minutes.

That call reports `Total cost: $0.0000` and `0 input, 0 output` — it costs
nothing and consumes no quota. The CLI throttles its own re-fetch at roughly
6 minutes, which is where that interval comes from.

The app never parses the CLI's printed panel; it only uses the command for its
side effect and reads the JSON it writes. Display text changes between releases,
structured data doesn't.

The snapshot time is always on screen (`วัดไว้ HH:mm`) because a percentage that
can be minutes stale should say so.

### Cost is notional on a subscription

Costs are what the same tokens would bill at API rates, marked with `≈`. A
subscription is not charged per token. The totals run ~95% cache reads — the
cheapest token type, and a sign caching is working — which is exactly why cost,
not token count, is the headline.

## Signing

`make-signing-cert.sh` creates a self-signed code signing certificate in your
login keychain. This is about permission prompts, not security theatre.

macOS keys TCC grants to an app's *designated requirement*. Ad-hoc signing puts
the cdhash in that requirement, and the Swift compiler emits a different binary
on every recompile — even for byte-identical source. So each build looks like a
brand new app and macOS re-asks for every permission. Signing with a certificate
makes the requirement `(bundle id + certificate root)`, which survives rebuilds.

The certificate is self-signed, lives only in your login keychain, is **not**
added to the system trust store, and is **not** a trusted root — `codesign` does
not need any of that. Its only capability is Code Signing.

## Icons

```sh
./install-icon.sh path/to/image.png [--strip-bg]   # menu bar icon
./make-appicon.py path/to/image.png                # app icon (Finder, Login Items)
```

Artwork is scaled nearest-neighbour so blocky art stays blocky, and trimmed to
its alpha bounding box first so canvas padding doesn't shrink the subject.

## Verifying

The app can run its own code paths headlessly, which is how the behaviour above
was checked rather than assumed:

```sh
./.build/release/ClaudeUsage --dump        # scan + pricing, per bucket
./.build/release/ClaudeUsage --live-test   # CLI discovery + spawn, did the snapshot move?
./.build/release/ClaudeUsage --login-test  # SMAppService register/unregister
```

## Privacy

Everything stays local. The app reads `~/.claude.json` and `~/.claude/projects`,
and runs the local `claude` CLI. It makes no network requests of its own and
needs no TCC permissions — if macOS asks for folder access on its behalf, denying
it changes nothing.
