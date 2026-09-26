# Getting the app onto a phone

Four ways, and which one you can use is decided entirely by what kind of Apple
account you have.

---

## The account question, first

Run this:

```bash
security find-identity -v -p codesigning
```

- **Only `Apple Development: …`** → free personal team. Cable-only. No TestFlight.
- **`Apple Distribution: …` as well** → paid Apple Developer Program. TestFlight works.

Or check a provisioning profile's lifetime — the giveaway is unambiguous:

```bash
for p in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision; do
  security cms -D -i "$p" | plutil -extract ExpirationDate raw - 
done
```

**Seven days is a free personal team. A year is a paid membership.**

---

## 1. Cable (free personal team)

What this repo can do today.

```bash
xcrun devicectl list devices          # find the identifier

xcodebuild -project SpatiumDDI/SpatiumDDI.xcodeproj -scheme SpatiumDDI \
  -destination 'platform=iOS,id=<DEVICE-ID>' \
  -skipPackagePluginValidation -allowProvisioningUpdates \
  -derivedDataPath /tmp/dd build

xcrun devicectl device install app --device <DEVICE-ID> \
  /tmp/dd/Build/Products/Debug-iphoneos/SpatiumDDI.app
xcrun devicectl device process launch --device <DEVICE-ID> io.spatiumddi.SpatiumDDI
```

**The app stops launching after seven days** and needs reinstalling. That is
Apple's limit on free accounts, not a project one.

## 2. Wireless, same network (free personal team)

Pair once over a cable in **Xcode → Window → Devices and Simulators → Connect via
network**. After that `devicectl` reaches the phone whenever both are on the same
LAN — no cable, but still the same seven-day expiry, and it does **not** work
across the internet or over a VPN, because discovery is Bonjour.

## 3. TestFlight (needs the paid membership)

The one that works when you're nowhere near the Mac. Up to 100 internal testers,
builds arrive in the TestFlight app, and they last 90 days rather than seven.

**Requires the Apple Developer Program — currently 99 USD/year.** There is no
free tier for TestFlight, no trial, and no workaround; App Store Connect will not
accept a build signed by a personal team.

Once enrolled:

1. **App Store Connect → Users and Access → Integrations → App Store Connect
   API** → create a key with the **App Manager** role. Download the `.p8`; you
   only get one chance.
2. **App Store Connect → Apps → +** → create the app record for
   `io.spatiumddi.SpatiumDDI`.
3. Add four repository secrets (**Settings → Secrets and variables → Actions**):

   | Secret | Where it comes from |
   |---|---|
   | `APP_STORE_CONNECT_ISSUER_ID` | shown above the key list |
   | `APP_STORE_CONNECT_KEY_ID` | the key's ID |
   | `APP_STORE_CONNECT_PRIVATE_KEY` | the whole `.p8`, including the BEGIN/END lines |
   | `APPLE_TEAM_ID` | your ten-character team ID |

4. Push a tag:

   ```bash
   git tag v1.0.0 && git push origin v1.0.0
   ```

`.github/workflows/release.yml` archives, signs and uploads. It refuses with a
readable message rather than a signing error if any secret is missing, so it is
harmless to have in the repo before the account exists.

The build number is the Actions run number plus the attempt (`412.2`), because
App Store Connect rejects a version it has already seen — and a re-run after a
failed upload is exactly when that bites. The run number alone doesn't change on
a re-run; the attempt does.

## 4. Ad-hoc / enterprise

Also paid-only, and worse than TestFlight for this purpose: ad-hoc needs every
device UDID registered up front and re-signing to add one. Use TestFlight.

---

## Signing secrets never live in this repo

Per the project conventions: screenshots and store metadata are committed;
certificates, `.p8` keys and passwords are Actions secrets. The workflow writes
the key to a file rather than passing it as an argument, so it cannot appear in
a process list, and deletes it in an `always()` step.

The same reasoning applies to test tokens — see
[DEVELOPMENT.md](DEVELOPMENT.md), where passing a token by value rather than by
path had to be fixed after two lab tokens were leaked into build logs.
