# TokenCounter (macOS)

A native SwiftUI app that reads Claude Code's session logs (`~/.claude/projects/**/*.jsonl`)
and reports token usage and cost, broken down by model, by project, by session,
and over a date/time range you choose.

**Everything runs locally.** No Anthropic API, no account, no credentials, and no
usage data ever leaves the machine. The single optional network call is an
anonymous request for a static rate file (see [Pricing](#pricing)); switch it off
and the app is still complete and correct.

> **The dollar figures are Anthropic first-party API list prices — not a bill.**
> They do not reflect a Claude Max or Pro subscription, Bedrock or Vertex partner
> rates, or batch discounts. If you are on a subscription you are not billed per
> token at all; read the totals as what that usage would cost at list price.

## Install

```sh
brew install --cask wdremington/tap/tokencounter
```

The release is signed with a Developer ID and notarized, so it launches without
a Gatekeeper warning. Requires macOS 14 (Sonoma) or later; the cask declares
this, so an older system gets a clear message rather than a broken install.

### Build from source

Requires only the Xcode **Command Line Tools** (`xcode-select --install`); a full
Xcode install is not needed.

```sh
./build.sh              # ad-hoc signed, for local development
./build.sh --install    # also copy it to /Applications
```

An ad-hoc build is not notarized, so the first launch needs right-click → Open.

## Features

- **Custom date *and* time ranges.** Rolling presets (last hour / 24h / 7 / 30 /
  90 days), calendar presets (today, yesterday, this week/month, last month, this
  year), all time, or a custom range whose endpoints carry a time of day.
- **Chart granularity** — hourly, daily, weekly, monthly, or automatic. A pinned
  granularity that would draw thousands of marks is coarsened automatically.
- **Breakdowns by model, project, and session**, with input / cache write / cache
  read / output / thinking token splits. The session table is what answers "which
  conversation made yesterday expensive?" — a model or project rollup cannot.
- **Cost broken out by token class.** Where the money actually goes, in dollars:
  input, cache write, cache read, output, and any long-context surcharge as its
  own line.
- **Editable pricing** — override any model's rate, or price a model released
  after this build. See [Pricing](#pricing).
- **Budgets** — daily and monthly limits with a progress bar in the menu bar and
  the dashboard, and a notification at a warning threshold and at 100%. Each
  threshold fires at most once per period, and that is remembered across
  relaunches, so a budget you have already passed does not nag you on every
  launch.
- **Usage history that outlives the logs.** Claude Code prunes
  `~/.claude/projects`; TokenCounter mirrors deduplicated responses into one file
  per month under Application Support and merges them back at launch.
- **Configurable log directory**, because `CLAUDE_CONFIG_DIR` moves it and an app
  launched from Finder never sees a shell variable.
- **Live updates** — the log directory is watched with FSEvents and rescanned
  incrementally, reading only the bytes appended since the last pass.
- **CSV export** of the current range, including the per-token-class cost split.

## Pricing

Rates resolve in three layers, highest priority first:

1. **Your overrides** — typed in Settings › Pricing, matched on the exact model id.
2. **A refreshed catalog** — one anonymous HTTPS GET for a static JSON file,
   cached to disk, validated before it is accepted, and silently ignored on any
   failure so the last good table is kept. Toggleable, and off entirely in a
   build with no catalog URL compiled in.
3. **The bundled table** — compiled into the app. Always present, so the app is
   fully functional offline.

Layers merge **per entry**, so overriding one model never hides the rest of the
table. A model with no entry anywhere is counted as $0 and flagged in the UI, with
a one-click path to setting a rate — understated rather than silently wrong.

To publish a refreshed catalog, generate it from the compiled table rather than
maintaining it twice:

```sh
build/TokenCounter.app/Contents/MacOS/TokenCounter --dump-catalog > pricing/catalog.json
```

then point `PricingStore.catalogURL` at wherever you serve it.

## Correctness notes

These are the things that make the numbers differ from a naive reading of the
logs. All are covered by the test suite.

**Streaming snapshots are collapsed.** Claude Code appends a fresh log line as a
response streams, so a single API response appears many times (up to 28 in the
sample corpus) — identical input and cache counts, growing `output_tokens`. Each
API message id is therefore counted **once**, taking the snapshot with the
highest output count. Counting every line instead overstates spend by roughly
**2.3×**. Duplicates also occur across files when a resumed session replays its
history, so the collapse is global rather than per-file.

**The 1M-context tier is a real price change for two models.** Claude Code writes
the active context tier as a bracket suffix (`claude-sonnet-4-5[1m]`). For almost
every model the tier does not change the rate — but Sonnet 4 and Sonnet 4.5 under
the 1M-context beta billed the **entire request** at 2× input and 1.5× output once
total input passed 200K. Three things about that are easy to get wrong, and are
tested: it is not a marginal tier (the whole request is multiplied, not the excess);
cache reads count toward the threshold; and the input multiplier applies to cache
writes and cache reads too, since those are input-side tokens. No
currently-served model carries a premium.

**Cache writes are priced by TTL.** A 5-minute-TTL write costs 1.25× the base
input rate; a 1-hour write costs 2×. The app reads the
`usage.cache_creation.ephemeral_{5m,1h}_input_tokens` split rather than the flat
total.

**Cache reads cost 0.1× input**, except where a model prices them outright —
Fable 5.1 and Mythos 5.1 read at $0.25/MTok, which is not 0.1 × $10.

**Thinking tokens are not double-counted.** They are already inside
`output_tokens` and are reported separately for information only.

**"Total tokens" is a volume measure, not an invoice.** It weights a cache-read
token the same as an output token, which in dollars they are not — a cache read
is roughly 1/50th the cost. Use the cost columns for anything money-shaped.

**Projects are identified by full path.** The last two path segments are not
unique: `/alice/work/api` and `/bob/personal/api` would collide into one row.
Identity is the whole working directory, and the displayed label is the shortest
suffix that stays unique among the projects actually in range.

**Flattened directory names are never un-flattened.** Claude Code names each log
directory after the working directory with `/` replaced by `-`, which is not
reversible — `/Users/d/my-app` would come back as a fabricated `/Users/d/my/app`.
For an entry with no `cwd`, the real path is taken from the most common `cwd`
observed in the same directory; only if a directory has none anywhere is the
flattened name used, and then verbatim.

**Partial lines are deferred.** Claude Code writes to these files while the app
reads them, so a half-written trailing line is left for the next pass rather
than dropped.

**History stores tokens, never dollars.** That is what lets archived usage
re-price itself when rates change or you edit an override. One damaged month file
is quarantined rather than deleted, and never costs you the other months.

## Headless modes

```sh
build/TokenCounter.app/Contents/MacOS/TokenCounter --audit         # print totals and exit
build/TokenCounter.app/Contents/MacOS/TokenCounter --test          # run the test suite
build/TokenCounter.app/Contents/MacOS/TokenCounter --dump-catalog  # print the rate table as JSON
```

`--audit` prices with the bundled table only — no network, no overrides — so two
runs on the same logs are comparable.

## Tests

```sh
build/TokenCounter.app/Contents/MacOS/TokenCounter --test
```

229 checks covering pricing resolution and layering, cost arithmetic, the
long-context premium, duplicate collapsing, range and granularity resolution,
aggregation, project label disambiguation, `cwd` resolution, series-color
stability, budget thresholds and alert deduplication, the archive (round trip,
merge order, corruption, quarantine, schema refusal), and the scanner end to end
including incremental rescan, appended lines, partial trailing lines, and file
truncation.

One of those checks exists to protect an invariant worth naming: **repricing is a
recompute, not a rescan.** `UsageRecord` carries no cost, so changing a rate
re-runs aggregation over the records already in memory and never invalidates the
scanner's incremental file cache.

The suite lives in `Sources/TokenCounter/Support/SelfTest.swift` rather than a
SwiftPM `testTarget`, because both XCTest and swift-testing ship with Xcode and
this package targets a Command Line Tools install. If you install Xcode, the
checks port to a `testTarget` mechanically.

## Releasing

`./build.sh --release` runs the self-test, builds, signs with a Developer ID
under the hardened runtime, notarizes and staples both the app and a `.dmg`, and
prints the sha256 to paste into the cask. Both `notarytool` and `stapler` ship in
the Command Line Tools, so no full Xcode install is needed.

One-time setup:

1. Install a **Developer ID Application** certificate into the login keychain
   (check with `security find-identity -v -p codesigning`).
2. Store notarization credentials once — an App Store Connect API key is
   preferred over an Apple ID, since it is org-wide and does not break on 2FA:

   ```sh
   xcrun notarytool store-credentials "tokencounter-notary" \
     --key AuthKey_XXXX.p8 --key-id KEYID --issuer ISSUER-UUID
   ```

3. Create the GitHub repo, plus a second one named `homebrew-tap` with
   `Casks/tokencounter.rb` in it (copy from `Casks/` here).

No entitlements file is used or needed. Hardened-runtime entitlements are
opt-*outs* from runtime hardening, none of which this app wants;
`com.apple.security.network.client` is an App Sandbox entitlement and is
irrelevant outside the sandbox. The app is deliberately not sandboxed, because it
reads `~/.claude/projects`.

The official `homebrew/cask` tap enforces a notability floor (roughly 30 forks /
30 watchers / 75 stars, checked in CI), so a new project should ship through its
own tap. For the user, `brew install --cask wdremington/tap/tokencounter` behaves
identically.

## Layout

```
Sources/TokenCounter/
  TokenCounterApp.swift     app entry, window + menu bar + settings scenes
  Model/
    Pricing.swift           rate catalog, layering, cost arithmetic, 1M premium
    UsageRecord.swift       one billable response; dedup rule; project labeller
    LogScanner.swift        JSONL discovery, incremental parsing, dedup, cwd map
    DateRange.swift         presets, bucket units, granularity
    Aggregates.swift        filtering, rollups, series, color slots
  Store/
    UsageStore.swift        observable state, selection, persistence
    PricingStore.swift      overrides > refreshed catalog > bundled table
    UsageArchive.swift      per-month history that outlives the logs
    BudgetStore.swift       limits, thresholds, deduplicated notifications
    DirectoryWatcher.swift  FSEvents wrapper
  Views/                    dashboard, chart, tables, menu bar, settings
  Support/
    Palette.swift           validated categorical chart palette
    Formatters.swift        number/date formatting
    Copy.swift              wording that must match everywhere
    AppPaths.swift          where the app keeps its own files
    SelfTest.swift          the test suite
    Audit.swift             --audit and --dump-catalog headless modes
Casks/tokencounter.rb       Homebrew cask, to copy into a homebrew-tap repo
pricing/catalog.json        generated by --dump-catalog; served for refresh
Tools/MakeIcon.swift        draws the app icon at build time
build.sh                    compile, test, bundle, sign, notarize, install
```

## Chart palette

Eight categorical hues in a fixed order, with separate light and dark steps of
the same hues. The ordering is a colorblind-safety mechanism, not a cosmetic
choice: it clears adjacent-pair CVD and normal-vision separation thresholds in
both modes. Colors are assigned per model from the model's rank by **token
volume** across the whole dataset — not the filtered range, and not spend, so
neither narrowing the date range nor editing a rate repaints the series that
remain. A ninth model folds into "Other" rather than inventing a ninth hue.

## Contributing and license

See [CONTRIBUTING.md](../CONTRIBUTING.md) for the development workflow and
release process. The app version lives in `VERSION`. TokenCounter is licensed
under the [Apache License 2.0](../LICENSE).
