#!/usr/bin/env bash
# Boot a simulator for a test run, wait for it to settle, and quiet it.
#
#   ./scripts/boot-simulator.sh "platform=iOS Simulator,id=<udid>"
#
# Takes the destination pick-simulator.py prints. Run the tests against it with
# `-parallel-testing-enabled NO` — parallel testing boots a fresh *clone* of
# this device instead, which undoes everything below.
#
# Why quiet it: on the iOS 27 runtime a hosted runner can't hold a connection
# to Apple's development push servers, and the simulator's push daemon, apsd,
# retries in a tight loop — about 1,700 TLS handshakes in two minutes, each
# with Keychain and trustd work. The simulator's daemons are host processes,
# so on a three-core runner that starved everything else: the local TLS stub
# took 107 seconds to answer a ClientHello and every trust test timed out,
# while the same tests pass in a quarter of a second without it. Nothing under
# test uses push, so apsd is stopped outright.
set -euo pipefail

destination="${1:?usage: $0 <xcodebuild destination with id=>}"
udid="${destination##*id=}"

xcrun simctl shutdown all >/dev/null 2>&1 || true
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b

# `bootout` unloads the job, so launchd does not restart it on demand. The
# warning it prints about the service identifier is harmless.
xcrun simctl spawn "$udid" launchctl bootout system/com.apple.apsd 2>/dev/null || true
if xcrun simctl spawn "$udid" launchctl list | grep -q com.apple.apsd; then
  echo "warning: apsd is still running on $udid" >&2
else
  echo "simulator $udid booted; apsd stopped"
fi
