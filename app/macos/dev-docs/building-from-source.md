# Building HyperWhisper for macOS from source

Running your own build is a supported path — local transcription needs no
account and no network. But the checked-in project is configured for **signed
release builds**, so opening it in Xcode and pressing ⌘R fails on a fresh clone:

```
error: Signing for "hyperwhisper" requires a development team.
Select a development team in the Signing & Capabilities editor that matches
the selected profile "HyperWhisper Developer ID".
```

This guide covers the setup, and the non-obvious failures that follow it.

## Quick start

```bash
cd app/macos
./scripts/build-local.sh --run
```

Requires macOS 14+, Xcode, and an Apple Development certificate (a **free**
Apple ID is enough — Xcode → Settings → Accounts → Manage Certificates → **+**).
Swift Package Manager resolves dependencies automatically.

On first launch, grant **Microphone** and **Accessibility** when prompted.
Accessibility is what lets HyperWhisper paste transcribed text into other apps.

## Why a plain build fails

Two separate things block a fresh clone.

**1. The project is pinned to the release provisioning profile.** `DEVELOPMENT_TEAM`
is empty and `PROVISIONING_PROFILE_SPECIFIER` names a profile only the release
team holds.

**2. The dev entitlements request an iCloud container.**
`hyperwhisper-dev.entitlements` names `iCloud.com.hyperwhisper.hyperwhisper`.
An iCloud container can only be provisioned by the team that owns it, so
requesting it from any other team forces a provisioning profile and fails —
even when everything else is configured correctly.

`scripts/build-local.sh` resolves both: it passes local signing settings on the
command line and points `CODE_SIGN_ENTITLEMENTS` at
`hyperwhisper/hyperwhisper-local.entitlements`, which is the dev entitlements
file with the iCloud keys removed. The checked-in project is never modified, so
this keeps working as upstream changes.

## Sign with a certificate, not ad-hoc

Ad-hoc signing (`CODE_SIGN_IDENTITY="-"`) builds and runs, but causes a
confusing, recurring problem.

macOS TCC ties a permission grant to the app's **code identity**. With a real
certificate that identity is *bundle id + certificate*, which is stable across
rebuilds. With ad-hoc signing it is derived from the **binary hash**, so **every
rebuild silently invalidates your grants**.

The symptom is memorable: Accessibility shows HyperWhisper enabled in System
Settings, but the app insists it lacks permission, and toggling the switch
changes nothing. The stored grant refers to a build that no longer exists.

Use a certificate and grant permissions once.

### Finding your team ID

The team ID is the certificate's **OU** field. It is *not* the value shown in
parentheses in the certificate name — that is a local certificate identifier.
Using it produces a genuinely confusing error that echoes back the same value it
says it cannot find:

```
No certificate for team 'XXXXXXXXXX' matching
'Apple Development: you@example.com (XXXXXXXXXX)' found
```

To read the real value:

```bash
security find-certificate -c "Apple Development: you@example.com" -p \
  | openssl x509 -noout -subject
```

The build script does this for you.

## If you previously installed an official release

Two pieces of state survive uninstalling the app, and both cause failures that
look like bugs in your build.

### Core Data store is newer than your checkout

The app crashes at launch with:

```
The model used to open the store is incompatible with the one used to create the store
```

Core Data migrates **forward only**. If the release you were running shipped a
newer model version than your checkout, its store cannot be opened by an older
model, and the app calls `fatalError` during store load.

Archive the store and let your build create a fresh one:

```bash
cd ~/Library/Application\ Support/hyperwhisper
for f in HyperWhisper.sqlite*; do mv "$f" "$f.bak"; done
```

Transcript history is not lost — it stays in the `.bak` files and can be read
with `sqlite3` — but it will not appear in the app. Settings, API keys, and
license live in UserDefaults and the Keychain, so they carry over.

### Stale permission entries block new grants

TCC entries from the official build encode *its* code requirement (its signing
team). Your build cannot satisfy that, so grants are rejected no matter how many
times you toggle the switch. The Console shows:

```
Failed to match existing code requirement for subject com.hyperwhisper.hyperwhisper
and service kTCCServiceAccessibility
```

Clear them, then grant again:

```bash
for svc in Accessibility Microphone ListenEvent PostEvent; do
    tccutil reset "$svc" com.hyperwhisper.hyperwhisper
done
```

If a stale HyperWhisper row remains in System Settings → Privacy & Security →
Accessibility, select it and press **−** before re-granting.

## Verifying a build actually contains your changes

Debug builds are **split**: the real code lives in
`HyperWhisper.app/Contents/MacOS/HyperWhisper.debug.dylib`, while the
`HyperWhisper` executable beside it is a small launcher stub.

Inspecting the stub for your symbols gives a false negative. Check the dylib:

```bash
APP=<path to built HyperWhisper.app>
nm "$APP/Contents/MacOS/HyperWhisper.debug.dylib" | grep -i YourNewType
```

When several checkouts exist, map a checkout to its DerivedData directory by
`WorkspacePath` rather than picking the most recently modified bundle:

```bash
for d in ~/Library/Developer/Xcode/DerivedData/hyperwhisper-*; do
    echo "$(basename "$d") -> $(plutil -extract WorkspacePath raw "$d/info.plist")"
done
```

## What differs in a local build

- **iCloud vocabulary sync is unavailable.** The container belongs to the
  release team. The toggle is shown disabled, and the app falls back to a
  local-only store. Vocabulary still works; it just stays on the device.
- **Crash reporting is inert.** The Sentry DSN is injected at build time from
  `Configurations/*.xcconfig`, which is not committed. Without it Sentry never
  initialises. Verify with:
  `plutil -extract SentryDSN raw "$APP/Contents/Info.plist"`
- **HyperWhisper Cloud points at staging** in Debug builds. Irrelevant unless
  you use HyperWhisper Cloud as your provider; build Release for production.
- **Local transcription is unaffected**, as are cloud providers you configure
  with your own API keys.
