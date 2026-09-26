# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **GitHub Org:** https://github.com/spatiumnorth — renamed from `spatiumddi` in
> September 2026. Link to `spatiumnorth/…` only: the old handle is unclaimed, and a
> redirect through it would follow whoever registers it next.
> **Platform repo:** https://github.com/spatiumnorth/spatiumddi
> **Tracking issue:** [spatiumddi#884](https://github.com/spatiumnorth/spatiumddi/issues/884)
> **License:** Apache 2.0

---

## What This Is

The native mobile client for **SpatiumDDI**, an open-source DDI (DNS, DHCP, IPAM)
platform. This repo holds **only the app**. It talks to a SpatiumDDI control plane
over its public REST API and contains no server-side code.

iOS (SwiftUI) first. Android is deliberately un-decided — Kotlin native vs. KMP vs.
React Native is a Phase 4 call, not a commitment made now.

**This repo is a client of a contract it does not own.** Every behaviour question that
starts "what does the server do when…" is answered in `spatiumnorth/spatiumddi`, not here.

---

## Where Things Live

| What | Where |
|---|---|
| Anything the **app** does — features, UX, bugs, roadmap | **this tracker**, `spatiumnorth/spatiumddi-mobile` |
| Work the **platform** has to do — a new or changed REST endpoint, a server-side capability | `spatiumnorth/spatiumddi` |
| API reference | `docs/API.md` in the platform repo |
| Permission grammar | `docs/PERMISSIONS.md` in the platform repo |
| The API contract itself | `openapi.json`, a release asset on each platform release |

The test is: **could the app ship this without a server change?** If yes, it belongs here.
Say which server-side change an upstream issue needs, or it will sit unread among platform work.

---

## The API Contract

**Base URL:** `https://<host>/api/v1`

**Generate the client — never hand-transcribe models.** Each platform release attaches
`openapi.json` as a release asset. Pin one server version, generate against that exact
document, and commit the generated code. A hand-written `Codable` struct drifts from the
server within one release and the drift is silent.

```bash
gh release download <TAG> --repo spatiumnorth/spatiumddi --pattern openapi.json
```

A live control plane also serves the same document at `/api/openapi.json`, useful for
development against `main` — but never generate a shipped client from it.

### Version handshake

`GET /api/v1/version` — **public, no auth**. Returns `version` (the running CalVer
release, e.g. `2026.08.12-1`) plus release-check fields.

Gate features on this. Do not feature-probe by calling an endpoint and treating 404 as
"not supported" — a 404 is also what an RBAC-filtered or feature-module-disabled surface
returns, and the app cannot distinguish those.

> `GET /health/platform` (root path, also unauthenticated) reports component health,
> `demo_mode` and `maintenance_mode` — it does **not** carry a version. Use it for the
> maintenance/demo banner only.

### Auth

One `Authorization: Bearer <token>` header covers everything. The server accepts either a
JWT from `/auth/login` or an API token with the `sddi_` prefix.

**v1 uses per-device `sddi_` API tokens**, minted at "sign in on this device." Rationale:
the browser refresh token is HttpOnly-cookie-only by design and is never returned in a
response body, so a native app either reimplements a path-scoped cookie jar (fragile) or
needs a new server-side grant. The device-token path needs neither, and force-logout
already works through token revocation.

Deferred, with real work upstream when they land: SSO (needs
`ASWebAuthenticationSession` + PKCE + a registered redirect), and refresh-token session
parity.

`GET /api/v1/auth/me/permissions` returns everything needed for client-side gating.

---

## Non-Negotiables

1. **Generated API client only.** No hand-written request/response models.
2. **Tokens live in the Keychain, gated by biometrics.** Never `UserDefaults`, never a
   plist, never a log line. Redact `Authorization` in every logging path.
3. **Never persist API response data to disk.** No offline cache of subnets, leases,
   zones or records. A stale-but-plausible lease table is worse than an error state,
   because an operator cannot tell it is stale — and acting on it changes production
   networks. In-memory for the session, gone on background.
4. **Client-side permission gating is UX, not security.** The server enforces
   independently. Hiding a button is a courtesy; a 403 must still be handled and shown
   honestly, never swallowed into a blank screen.
5. **Honour maintenance mode.** During a change window the server 503s mutating requests
   with `Retry-After` and a message. Surface it as a real state — never retry into it,
   never present it as a network failure.
6. **Every write is confirmed.** This is an app for changing production DNS and DHCP from
   a phone, one-handed, possibly on a train. No destructive action lands on a single tap.
7. **No telemetry, analytics, or crash reporting that leaves the device** without an
   explicit opt-in. Operators run this self-hosted, frequently air-gapped; an app phoning
   home is a non-starter.
8. **Never disable TLS validation.** See below — the answer is trust, not bypass.

---

## Self-Hosted Reality

Assume the server is **not** a public host with a public CA cert. Typical deployments are
`https://ddi.internal.example` behind a private CA, or the OS appliance whose internal CA
is a self-signed root generated at first approve.

App Transport Security will reject those by default. The correct handling is an explicit,
user-visible trust flow — show the certificate's fingerprint and subject, make the operator
confirm it, pin what they accepted. A blanket `NSAllowsArbitraryLoads` or an
"accept all certificates" toggle is not an acceptable shortcut; it silently downgrades every
install, including the ones that had a valid cert.

Also expect: non-standard ports, HTTP-only lab installs the operator knowingly chooses,
and IP-literal hosts with no name at all.

---

## Phasing

Per [#884](https://github.com/spatiumnorth/spatiumddi/issues/884). Do not pull scope forward.

- **Phase 1 — read-mostly.** Sign-in, dashboard KPIs + health, global search, IPAM browse
  (space → block → subnet → IP), DNS zone/record view, DHCP scope/lease view, alert list.
  Native niceties: pull-to-refresh, biometric unlock.
- **Phase 2 — a small set of writes.** Acknowledge/resolve alerts, approve change requests,
  allocate next IP, toggle maintenance mode. Approvals-on-the-go is the best mobile write
  story; the rest of the platform's surface stays desktop work.
- **Phase 3 — push notifications.** Blocked on upstream: a device registry and an APNs/FCM
  alert channel do not exist server-side yet.
- **Phase 4 — Android.** Decide the stack then, on evidence.

Phase 0 (PWA groundwork) is upstream frontend work — [spatiumddi#902](https://github.com/spatiumnorth/spatiumddi/issues/902).

---

## UI Conventions

These are house style, not taste. Each one exists because the alternative was
tried on a phone and got in the way.

- **A sheet that creates or edits something puts its action in the navigation
  bar**, top right, as a **Save** pill
  (`ToolbarItem(placement: .confirmationAction)`) — never as a row at the foot
  of the form. At the foot it is the one control the keyboard covers, and on a
  long form it is also the one you have to go looking for. Cancel pairs with it
  on the left (`.cancellationAction`).
  The onboarding screens — Connect, Sign In — deliberately keep a bottom button:
  each is the end of a linear sequence, and the footer directly under it carries
  what the operator is agreeing to ("stored in the Keychain and unlocked with
  Face ID"). In the bar that text would be orphaned from its button.
- **Saving still confirms.** Non-negotiable #6 is unchanged: Save opens the
  confirmation, and the confirmation names the actual thing being written — the
  address and the subnet, the record in zone-file form — never "Are you sure?".
- **Say why a disabled Save is disabled**, in the form near the field at fault.
  A greyed-out button with no stated reason is a dead end.
- **Deleting asks the operator to type the name.** `DeleteConfirmationSheet`.
  Two taps clears non-negotiable #6 for most things; it does not clear it for a
  live DNS record, whose retraction reaches every server in the group before the
  sheet has dismissed. The platform gates its own blast-radius operations the
  same way (typed-CIDR on subnet resize), so this is house style on both sides.
  Say **what will happen**, not "this cannot be undone" — the two deletes this
  app can make differ, and getting the copy backwards is worse than none.
- **Every screen that takes text gets `.dismissableKeyboard()`.** It adds the
  keyboard-dismiss glyph above the keyboard and drag-to-dismiss on the scroll
  view. Not optional on numeric fields: `.numberPad` has no Return key, so
  without it there is no way out at all.
- **Nested browse screens carry `.breadcrumbs(_:)`** — the ancestors, not the
  root and not the current level, since the title already says that.
- **Server text is never localised or Markdown-parsed.** `Text(verbatim:)` or
  `FailureMessage.server`; this app's own words use `LocalizedStringResource`.
  See `FailureMessage` for what goes wrong otherwise.

---

## Conventions

- **Versioning:** semver for the marketing version, monotonic build number. This repo does
  **not** follow the platform's CalVer — App Store Connect will not accept it.
- **Minimum server version:** state it explicitly in the app and check it at sign-in.
  Refusing to connect with a clear message beats half-working against an old control plane.
- **Branch per issue**, named for the upstream issue where one exists (`issue-884-signin`).
- **Never push to `main` or open a PR without being asked.** Pushing a branch on request
  is fine; that is a separate step from opening a PR.
- **No scratch files in the repo tree.** Check `git status --short` before committing;
  never blind `git add -A`.
- **Screenshots and store metadata** live in the repo; signing secrets and API keys never
  do — those are Actions secrets.
