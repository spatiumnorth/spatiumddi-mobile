# Development

Building, testing and changing the app. For how it's structured and why, see
[ARCHITECTURE.md](ARCHITECTURE.md).

---

## Prerequisites

- **macOS** with **Xcode 16** or later (Swift 6 language mode)
- An iOS 18+ simulator, or a device in developer mode
- `gh` for release assets and issues (optional)
- Python 3 for the helper scripts (ships with macOS)

```bash
git clone https://github.com/spatiumnorth/spatiumddi-mobile.git
cd spatiumddi-mobile
open SpatiumDDI/SpatiumDDI.xcodeproj
```

The project uses Xcode's file-system-synchronized groups, so **a new `.swift`
file anywhere under `SpatiumDDI/SpatiumDDI/` is compiled automatically** — no
project-file edit, and no merge conflict in `project.pbxproj`.

## Building from the command line

```bash
xcodebuild -project SpatiumDDI/SpatiumDDI.xcodeproj \
           -scheme SpatiumDDI \
           -destination 'generic/platform=iOS Simulator' \
           -skipPackagePluginValidation \
           build
```

`-skipPackagePluginValidation` is not optional. The OpenAPI generator runs as a
build-tool plugin, and without the flag a non-interactive build blocks waiting
for plugin approval that nobody is there to give. CI passes it; so should you.
(Xcode's GUI asks once and remembers, which is exactly why forgetting the flag
locally goes unnoticed until CI hangs.)

---

## The stub control plane

Most tests need a server that speaks TLS with a certificate the system won't
validate — the situation every real self-hosted install puts the app in.

```bash
./scripts/dev-control-plane.sh start   # two instances: healthy + in maintenance
./scripts/dev-control-plane.sh stop
./scripts/dev-control-plane.sh test    # start, run the suite, stop
```

It serves `/health/platform` over TLS on `localhost:8443` (healthy) and
`localhost:8444` (permanently in a change window), with a self-signed
certificate generated on first run into `.dev-control-plane/` (git-ignored).

It binds **dual-stack** deliberately. An IPv4-only stub looks fine locally,
because macOS falls back — but `localhost` resolves to `::1` first, and on a CI
runner with no fallback the connection hangs until it times out and the trust
test fails with a misleading error.

### Driving the app against a real HTTP lab

The app is HTTPS-only. If your lab control plane speaks plaintext, terminate TLS
in front of it with the same dev certificate:

```bash
./scripts/dev-control-plane.sh proxy http://ddi.lab.internal:8077
```

---

## Tests

Four tiers, with different requirements. `dev-control-plane.sh test` runs 98 of
them green; the contract tier adds ten more when a lab is configured. Tiers 3
and 4 skip when one isn't, so a contributor without a control plane still gets a
green — and still meaningful — run.

### 1. Unit tests — no server needed

Pure logic: address parsing, version comparison, severity mapping, TTL
formatting, health-payload parsing, the weighted-utilisation arithmetic, the
session state machine, redaction.

```bash
./scripts/dev-control-plane.sh test
```

### 2. Trust-flow tests — need the stub

Certificate challenge, pinning, maintenance detection. **They skip silently
without the stub**, which means a run can look green while the security-critical
assertions never executed. `dev-control-plane.sh test` exists so that doesn't
happen by accident.

### 3. Contract tests — need a live control plane

The ones that earn their keep. A compile proves the generated types exist; it
proves nothing about whether the server fills the fields the screens read. Both
bugs this tier has caught were of that kind — dropped nullable fields, and
microsecond timestamps the decoder rejected.

```bash
# Pass a PATH, not the token itself — see the warning below.
printf '%s' 'sddi_…' > /tmp/spatium-token && chmod 600 /tmp/spatium-token

export TEST_RUNNER_SPATIUM_LIVE_HOST='ddi.example.com'
export TEST_RUNNER_SPATIUM_LIVE_TOKEN_FILE='/tmp/spatium-token'

xcodebuild test -project SpatiumDDI/SpatiumDDI.xcodeproj -scheme SpatiumDDI \
  -destination "$(./scripts/pick-simulator.py)" \
  -skipPackagePluginValidation \
  -only-testing:SpatiumDDITests
```

They skip when those variables are unset, so they never block a contributor
without a lab.

> **Never put the token in `SPATIUM_LIVE_TOKEN`.** `xcodebuild` dumps its entire
> launch environment into the build log, so a token passed by value lands in
> plaintext on disk — and in CI artefacts, and in anything scraping build
> output. That is not hypothetical: it is how two lab tokens had to be revoked
> while this app was being written.
>
> `SPATIUM_LIVE_TOKEN_FILE` takes a path instead, and a path is not a secret.
> The by-value variable is still read as a fallback, so existing setups keep
> working — but prefer the file, mint short-lived tokens, and revoke them when
> you're done.

### 4. Screenshot / end-to-end — live server, and produces store assets

`ScreenshotUITests` drives the whole app against a real control plane and
captures every screen. It's the only test that proves a tab *renders* rather than
merely decodes, and it's how App Store screenshots get made — from the app
actually running, not a mockup.

```bash
export TEST_RUNNER_SPATIUM_LIVE_HOST='ddi.example.com'
export TEST_RUNNER_SPATIUM_LIVE_TOKEN_FILE='/tmp/spatium-token'
export TEST_RUNNER_SPATIUM_SHOT_DIR='/tmp/shots'

xcodebuild test … -only-testing:SpatiumDDIUITests/ScreenshotUITests
```

The simulator needs **either** a biometric enrolment (**Features → Face ID →
Enrolled**) or a device passcode set. With neither, the token store refuses to
save — which is the security rule working, not a bug. With only a passcode the
app runs, and says so: `KeychainProtection` falls back to `.devicePasscode` and
the sign-in screen names the weaker gate before the token is stored.

> **Known flake:** the XCUITest runner app intermittently fails to launch
> (`Simulator device failed to launch …xctrunner`). It is a runner-bootstrap
> problem, not a test failure — retry, or run it from Xcode. This is also why UI
> tests run only on `main` in CI and not on pull requests.

The walk drills IPAM to an address and DNS to a record list. By default it
descends into the **first populated row** at each level — which on a demo
estate is as likely to be an empty multicast block as the office subnet the
screenshots are for. Tell it where to go instead, by row text:

```bash
export TEST_RUNNER_SPATIUM_IPAM_SPACE='Corporate'
export TEST_RUNNER_SPATIUM_IPAM_BLOCK='10.0.0.0/8'
export TEST_RUNNER_SPATIUM_IPAM_SUBNET='10.1.0.0/24'
export TEST_RUNNER_SPATIUM_DNS_GROUP='default'
export TEST_RUNNER_SPATIUM_DNS_ZONE='windows.lab.local'
export TEST_RUNNER_SPATIUM_DHCP_SERVER='dhcp-kea'
```

Matching is case-insensitive substring against the visible row, so a network,
a name, or a distinctive fragment of either all work. The write sheets the walk
opens on the way — allocate, new record, and the typed delete gate — are always
**cancelled**; the test must never mutate the estate it is pointed at.

The captures land in the result bundle as attachments, and as PNGs in
`SPATIUM_SHOT_DIR`. They are the README and App Store set: re-capture when a
shipped screen changes materially, not on every release. For the README's
dark-mode variants, run it again with a different shot directory and

```bash
export TEST_RUNNER_SPATIUM_APPEARANCE=dark
```

which the harness passes into the app's capture hook
(`SPATIUM_FORCE_APPEARANCE`, honoured in `SpatiumDDIApp` and inert on every
real launch). Flipping the simulator with `simctl ui … appearance dark` looks
equivalent and is not: it doesn't reliably reach a test-managed launch, and
the failure mode is a "dark" run of perfectly light captures.

> **Before publishing any capture, look at it.** The Connect, Sign In, Menu
> and Server screens show the control plane's **real host name**, and the walk
> was pointed at a real lab. The published README set deliberately uses only
> screens that never display the address; anything else needs the host blurred
> or the run repointed at a stub before it goes anywhere public.

---

## Strings and localisation

Every user-facing string goes through the string catalogue at
`SpatiumDDI/SpatiumDDI/Localizable.xcstrings`. The app ships English only, but
the *structure* is in place, which is the part that is expensive to retrofit.

Two rules keep it that way:

**Never hand a `String` to `Text`.** SwiftUI localises a string *literal*,
because that becomes a `LocalizedStringKey`. A `String` variable is rendered
verbatim and never reaches the catalogue. Anything that carries a message for
later display — `LoadState.failed`, everything `APIErrorMessage` returns — uses
`LocalizedStringResource` for exactly this reason. Failure messages are the text
an operator most needs to understand, so they are the worst thing to leave
untranslatable.

**Never route server text through a localised value.** `Text` parses Markdown
for a localised value, so a control plane's error `detail` of
`[Contact support](https://phish.example)` would render as a *tappable link*
inside the app's own error banner. And `LocalizedStringResource(stringLiteral:)`
sets the resource's **key**, so a `detail` of `Access` would be looked up in this
app's catalogue and render whatever the app's own "Access" label says. Use
`FailureMessage.server(_:)`, which renders through `Text(verbatim:)` — neither
parsed nor looked up. `FailureMessage.app(_:)` is for this app's own wording.

The same split applies to `Badge`: `Badge(localised:)` for words this app chose,
`Badge(text:)` for a value the server chose. Translating a zone type or a lease
state would misreport what the server said.

**Never build a plural by hand.** `"\(n) record\(n == 1 ? "" : "s")"` is correct
in English and wrong nearly everywhere else — Polish has three plural forms,
Arabic six. Use inflection instead:

```swift
Text("^[\(count) record](inflect: true)")
```

Xcode merges extracted strings into the catalogue when you build **in the IDE**.
`xcodebuild` emits the same `.stringsdata` but does not merge it, so a
command-line-only workflow leaves the catalogue stale. After adding strings:

```bash
xcodebuild -project SpatiumDDI/SpatiumDDI.xcodeproj -scheme SpatiumDDI \
  -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation build

./scripts/build-string-catalog.py \
  ~/Library/Developer/Xcode/DerivedData/SpatiumDDI-*/Build
```

The script only ever adds keys. A string missing from one build may just be
behind code that build did not compile, and discarding a translator's work on
that guess is not a trade worth making. It exits non-zero if it read nothing at
all, because a run that silently rewrote the catalogue from no input is exactly
the staleness it exists to prevent.

It reads only the **app** target. String extraction is deliberately off for the
test bundles: a literal in a test would otherwise be merged in and shipped to
translators permanently, since nothing removes keys.

### What is already correct without translation

Dates, numbers and relative times go through `.formatted()`; sorting uses
`localizedStandardCompare`; filtering uses `localizedCaseInsensitiveContains`.
Those adapt to the device locale today, in an English-only build. SwiftUI's
leading/trailing layout means right-to-left works without changes.

**iOS does not translate your strings.** It localises its own UI and formats
dates and numbers; the words in this app stay English until someone writes the
translations.

---

## Formatting

CI lints strictly; fix locally before pushing.

```bash
xcrun swift-format format --in-place --recursive \
  SpatiumDDI/SpatiumDDI SpatiumDDI/SpatiumDDITests SpatiumDDI/SpatiumDDIUITests

xcrun swift-format lint --recursive --strict \
  SpatiumDDI/SpatiumDDI SpatiumDDI/SpatiumDDITests SpatiumDDI/SpatiumDDIUITests
```

---

## Re-pinning the API client

When a new platform release lands:

```bash
gh release download <TAG> --repo spatiumnorth/spatiumddi --pattern openapi.json \
  --output Packages/SpatiumAPI/Sources/SpatiumAPI/openapi.json

shasum -a 256 Packages/SpatiumAPI/Sources/SpatiumAPI/openapi.json
```

Then, in `Packages/SpatiumAPI/Sources/SpatiumAPI/openapi-generator-config.yaml`,
update the release tag and checksum in the header comment. And in
`SpatiumDDI/SpatiumDDI/Networking/ServerVersion.swift`, update
`SupportedServer.minimum` to match — **the minimum supported server is the release
the client was generated from**, and letting those two drift apart is how the app
starts claiming a compatibility nobody verified.

Rebuild, then run the contract tests against a live server on that release. A
successful compile is not evidence the contract still holds.

### Adding a screen

Add its paths to the `filter.paths` list in the same config file first — the
document describes 842 paths and only the filtered subset is generated, so the
operation you want won't exist until you list it.

Find the generated names with:

```bash
cd Packages/SpatiumAPI && swift build
grep -oE 'public func [a-zA-Z0-9_]+' \
  .build/plugins/outputs/spatiumapi/SpatiumAPI/destination/OpenAPIGenerator/GeneratedSources/Client.swift
```

---

## Running on a device

1. Xcode → **Signing & Capabilities** → select your team.
2. Plug in the device, enable **Developer Mode** on it (Settings → Privacy &
   Security), and trust the Mac.
3. Select it as the run destination and build.

From the command line, first registration needs:

```bash
xcodebuild -allowProvisioningUpdates -allowProvisioningDeviceRegistration …
```

A personal team allows a small number of devices and the provisioning profile
expires after seven days — that's Apple's limit, not a project one.

---

## CI

Two workflows, both on push to `main` and on pull requests.

| Workflow | Job | Runs on |
|---|---|---|
| `ci.yml` | `swift-format` lint | always |
| | Build & test (unit + trust, against the stub) | always |
| | UI tests | **`main` only**, with retry |
| `security.yml` | Trivy (SHA-pinned) | always |
| | CodeQL | always |

UI tests are kept off the pull-request path on purpose: the runner app's
bootstrap isn't dependable on a hosted machine, and a run in which all unit tests
passed was once failed by the runner being killed before it could connect. A
flake shouldn't block a review.

`scripts/pick-simulator.py` chooses a device that actually exists on the runner,
because the simulator line-up changes with the Xcode image and a pinned model
name eventually stops resolving.

---

## Conventions

- **Branch per issue**, named for the upstream issue where one exists —
  `issue-884-signin`.
- **Never push to `main`, and never open a PR without being asked.** Pushing a
  branch on request is fine; opening a PR is a separate step.
- **No scratch files in the repo tree.** Check `git status --short` before
  committing; never blind `git add -A`.
- **Versioning:** semver marketing version, monotonic build number. This repo
  does *not* follow the platform's CalVer — App Store Connect won't accept it.
- **Screenshots and store metadata** live in the repo. Signing secrets and API
  keys never do — those are Actions secrets.
