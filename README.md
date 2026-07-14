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

`./build.sh --universal` produces an arm64 + x86_64 bundle instead of a native
one. It builds each slice with `--triple` and `lipo`s them together, because
`swift build --arch a --arch b` needs xcbuild from full Xcode while `--triple`
only needs the Command Line Tools. It takes about twice as long, so it isn't the
default.

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

## Distribution — build it, don't hand the bundle over

**Sending someone the built `ClaudeUsage.app` does not work.** Have them clone
and run `./build.sh` instead. This is not caution; it's what the tools report:

```
$ spctl -a -vvv ClaudeUsage.app
ClaudeUsage.app: rejected
origin=ClaudeUsage Self-Signed
```

Gatekeeper rejects it because the signing certificate exists only in the
keychain of the machine that built it. Nobody else's Mac has ever seen it, and
it is deliberately not a trusted root. Stripping the quarantine attribute does
not help — the assessment still comes back `rejected`, because the problem is
the certificate, not where the file came from.

Your own build runs fine despite that same `rejected` verdict, which looks like
a contradiction until you notice Gatekeeper only *enforces* on quarantined
files. A locally built bundle was never quarantined, so it is never checked. The
identical bundle arriving by AirDrop or chat is. Same bytes, different outcome.

A recipient can force it (`xattr -cr ClaudeUsage.app`, then System Settings →
Privacy & Security → Open Anyway), but that teaches someone to wave through the
exact warning that protects them. Building from source costs less and skips the
problem entirely — no quarantine, no Gatekeeper, and their own architecture.

Distributing binaries properly means an Apple Developer Program membership
($99/yr), a Developer ID certificate, and notarization. That is the only path
that makes a downloaded copy open on a first double-click.

They will also need macOS 14+, Claude Code installed and used at least once
(otherwise there is no `~/.claude.json` to read), and — if you *do* ship a
bundle — an arm64 Mac, unless it was built with `--universal`.

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
