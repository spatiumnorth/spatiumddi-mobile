# Architecture

How the app is put together, and why it is put together that way. For how to
build, test and work on it, see [DEVELOPMENT.md](DEVELOPMENT.md).

---

## The shape of it

```
SpatiumDDI/SpatiumDDI/
├── SpatiumDDIApp.swift        the entry point
├── Networking/                reaching a control plane, safely
├── Security/                  Keychain, biometrics, redaction
└── Features/                  one folder per surface
    ├── AppFlowModel.swift     the session state machine
    ├── AppRootView.swift      the shell, and the tabs
    ├── Shared/                LoadState, badges, formatting
    ├── Connection/            connect + certificate trust
    ├── SignIn/                token entry, QR enrolment, unlock
    ├── Overview/              the landing screen
    ├── Alerts/  IPAM/  DNS/  DHCP/  Search/
Packages/SpatiumAPI/           the generated API client, as a local package
```

Three layers, and the dependency arrow only points one way: **Features → Networking → SpatiumAPI**.
`Security` is used by both of the upper two. Nothing in `Networking` imports a
view, and nothing in `Features` builds a `URLSession`.

---

## The API client is generated, never written

`Packages/SpatiumAPI` is a local Swift package wrapping
[swift-openapi-generator](https://github.com/apple/swift-openapi-generator) as a
build-tool plugin. Types and client code are produced at build time from
`Sources/SpatiumAPI/openapi.json`.

That document is **the release asset from a pinned platform release**, committed
byte-for-byte so anyone can verify it against what upstream published:

```bash
gh release download 2026.09.04-1 --repo spatiumnorth/spatiumddi --pattern openapi.json
shasum -a 256 openapi.json
# dc07aca3b4bb765297993a73b0b141d2ef7727d074724e789d4528ce3f0ae4d8
```

A live control plane serves the same document at `/api/openapi.json`, which is
useful while developing against `main` — but a shipped client is never generated
from it, because that document tracks a branch and is not a contract anyone
released.

### Why generation is a rule and not a preference

A hand-written `Codable` struct drifts from the server within one release, and
**the drift is silent**: a field the server stopped sending decodes as `nil`, a
field it renamed decodes as absent, and the screen renders as though the data
were simply empty. On an app whose entire job is telling an operator the truth
about a production network, that failure mode is disqualifying.

### The document is filtered

It describes 842 paths. Generating all of them produces an enormous client for a
few dozen screens, so `openapi-generator-config.yaml` filters to the Phase 1
surface. Adding a screen means adding its paths there first.

### Two client-side workarounds, both explained

- **`LenientDateTranscoder`** — the control plane emits microsecond-precision
  timestamps, which the default ISO-8601 transcoder rejects. This accepts them.
  Found by a contract test against the live lab, not by a compiler.
- **`SpatiumClient`'s middleware** — `BearerTokenMiddleware` attaches the token;
  `UnauthorizedMiddleware` notices a 401 and hands the session back to the flow
  model so the app locks rather than showing empty screens.

---

## Reaching a server

### `ServerAddress`

A parsed, validated control-plane address. **HTTPS only** — parsing anything else
throws `.unsupportedScheme`. Handles non-standard ports and IPv6 literals
(bracketing them for URL construction), and produces a `pinKey` that distinguishes
`host:443` from `host:8443`, because those are different servers.

### `ServerTrustDelegate`

The `URLSessionDelegate` that decides whether a TLS connection may proceed. Three
outcomes, and only three:

1. The system validates the chain → **proceed**.
2. It doesn't, but the leaf's SHA-256 matches a fingerprint this operator has
   already approved → **proceed**.
3. Otherwise → **refuse**, and record what was presented.

Case 3 drops the connection rather than prompting, because `URLSession` wants an
answer on a background queue immediately and a human cannot be consulted in that
window. The recorded certificate is what the connect screen then shows the
operator; once they approve it, the next attempt takes path 2.

There is no path that accepts an unvalidated, unapproved certificate.

### `ControlPlaneProbe`

Establishes whether an address is a reachable SpatiumDDI control plane, before
any credential exists. Uses an ephemeral `URLSession`, **reads status codes only
and never decodes a body**, and distinguishes "reachable", "in a change window",
"needs trust approval" and "failed" as separate outcomes.

### `ControlPlaneSession`

One authenticated connection, for the life of a session. It owns the
`URLSession`, so the generated client necessarily goes through this app's trust
policy — a client that made its own session would bypass the pin the operator
approved, which is the one thing the trust flow exists to prevent.

It is created in `@State` and explicitly invalidated. A `URLSession` with a
delegate retains that delegate until invalidated, so constructing one inline in a
`body` — which SwiftUI re-evaluates freely — leaks a session and a delegate on
every render.

---

## Credentials

### Why per-device API tokens, not a JWT session

The web console's refresh token is HttpOnly-cookie-only by design and is never
returned in a response body. A native app would therefore have to reimplement a
path-scoped cookie jar (fragile) or need a new server-side grant. The `sddi_`
device-token path needs neither, and force-logout already works through token
revocation.

SSO and refresh-token session parity are deferred, and both need real upstream
work when they land.

### `TokenStore`

Tokens go in the Keychain with `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`
and the strongest access control the device offers: `.biometryCurrentSet` where
biometrics are enrolled — so the entry is invalidated if the enrolment changes —
and `.devicePasscode` where they are not. Neither available means no write at
all. `KeychainProtection` is that choice, and it is stored as a Keychain
attribute beside the item so it can be read back without a prompt and cannot
drift from the item it describes.

The gate is enforced **in the store, not at the call sites**.
`SecAccessControlCreateWithFlags` will happily mint a `.biometryCurrentSet` policy
on a device with no enrolment (the simulator does exactly this), and `SecItemAdd`
then succeeds — storing a token that nothing would ever be asked to unlock. So
the store picks the policy itself and refuses when there is nothing to pick.
That property belongs to the store; a caller cannot forget it.

Reading back evaluates the policy matching the **item's** protection, not the
device's current capability: a passcode-satisfied `LAContext` does not unseal a
`.biometryCurrentSet` item, and a device that gained Face ID after a
passcode-only sign-in still holds a passcode-gated item until the next sign-in.

### `ServerRegistry`

Which control planes are configured, what the operator called them, and which
one is current. Plain `UserDefaults` — none of it is a secret. Each server's
token stays in its own Keychain item and each certificate pin in its own, both
already keyed by `pinKey` (`https://host:port`), so several servers means
several protected items and never a bundle in one blob.

Switching servers is a stage change, which tears `SignedInView` down and takes
the `ControlPlaneSession` and every screen's fetched rows with it. That is what
keeps "nothing an inactive server returned may linger" true by construction
rather than by remembering to clear things.

The plist this writes is the only file the app container holds, and it is why
the app carries the **Data Protection** entitlement
(`com.apple.developer.default-data-protection = NSFileProtectionComplete`):
internal control-plane host names should not be readable from a locked phone.
See `SECURITY.md` §3 — in particular the constraint it places on Phase 3, since
files at that class are unreadable while the device is locked.

### `Redaction`

The only sanctioned way to log a request. `redact()`, `redactHeaderValue()` and
`describe(_ request:)` exist so that no logging path can print an
`Authorization` header, even by accident.

---

## Session state

`AppFlowModel` is a five-stage machine:

```
servers ◀──▶ addServer ──connected──▶ signIn ──signedIn──▶ signedIn
     ▲                         ▲                    │
     │                         │              background
  changeServer            sessionRejected           │
     │                         │                    ▼
     └─────────────────────────┴──────────────── locked
```

- The **server address** is config, so it lives in `UserDefaults`. The **token**
  never does.
- **Locking happens as the app leaves the foreground**, not when it returns — the
  token must not be resident in memory while backgrounded.
- The unlock prompt is keyed on scene phase rather than on-appear, because
  locking fires the instant the app stops being active; a plain on-appear prompt
  is raised while backgrounded, cancelled by the system, and never comes back.

---

## Screens

### `LoadState` — four states, one shape

```swift
enum LoadState<Value> { case idle, loading, loaded(Value), failed(String) }
```

Failure is a first-class state rather than an empty list, because **a blank list
is exactly what "swallowed the error" looks like to an operator**. `LoadStateView`
renders all four consistently, including a distinct empty state.

### Every fetch switches; none uses `.ok`

The generated `.ok` shorthand throws an opaque `RuntimeError` for any status the
document doesn't declare — and this document declares only 200 and 422. A 401,
403 or 503 therefore arrives as `Output.undocumented(statusCode:)`, and **only the
call site can see it**. So every call site switches:

```swift
state = await LoadState.fetching {
    switch try await session.client.listZonesApiV1DnsGroupsGroupIdZonesGet(...) {
    case .ok(let ok):                   return try ok.body.json
    case .unprocessableContent:         throw APIStatusError(status: 422)
    case .undocumented(let code, _):    throw APIStatusError(status: code)
    }
}
```

`APIErrorMessage` then turns the status into something an operator can act on —
which is what makes the honest 403 and the real maintenance-window message
reachable at all. Using `.ok` would make every one of those messages dead code.

### Nothing is cached

There is no persistence layer, and that is deliberate. Response data is held in
view state for the session and is gone on background. A stale-but-plausible lease
table is worse than an error state, because an operator cannot tell it is stale —
and acting on it changes production networks.

---

## The overview composes what the server doesn't roll up

`/api/v1/dashboards/` carries exactly three summaries — **network** (ASN, RPKI,
circuits), **security**, and **integrations**. None of them counts a subnet, a
zone or a lease. The web console's nine dashboard tabs are composed client-side.

So `OverviewModel` counts from the resource endpoints, six calls concurrently,
each landing in its own `LoadState` so tiles fill in as they arrive rather than
blocking on the slowest.

Two decisions worth knowing:

- **Utilisation is weighted by subnet size, not averaged.** A full `/30` beside an
  empty `/16` averages to 50% only if you ignore that they differ in size by a
  factor of sixteen thousand. There is a test for this.
- **The top-N report endpoint is deliberately not called.**
  `/api/v1/reports/top-subnets-by-utilization` sits behind the `reports.top_n`
  feature module and answers **404** when it's disabled — the same status an
  RBAC-filtered surface returns. The app cannot distinguish those, so it ranks
  locally from data it already fetched rather than guessing.

That second point generalises: **never feature-probe by calling an endpoint and
reading 404 as "not supported."** Gate on `GET /api/v1/version` instead.

---

## Version gating

`ServerVersion` parses the platform's CalVer (`2026.08.22-1`) into comparable
parts, and treats anything else — `dev`, `latest`, a branch name — as a
`.development` case rather than as a parse failure sorted to the bottom.

A development build **passes** the minimum check, because a build from `main` is
by definition newer than any release and refusing it would lock the app out of
exactly the servers it is developed against. The overview then says plainly that
the version could not be checked. That is a permissive answer honestly labelled,
not a verified one.

The declared minimum is the release the client was generated from — the only
version whose contract this app has actually been compiled against.

---

## Concurrency

Swift 6 language mode, with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Value
types that cross isolation boundaries are marked `nonisolated` explicitly —
including model structs nested inside `@MainActor` types, which otherwise inherit
an isolation they don't need and can't be used from a synchronous test.

Concurrent fan-out uses `async let` for a fixed set of calls and
`withTaskGroup` for a variable one. Task-group results are accumulated with
`for await` rather than `reduce(into:)`, because the reducing closure is `inout`
across an isolation boundary and Swift 6 rejects it as a data race.
