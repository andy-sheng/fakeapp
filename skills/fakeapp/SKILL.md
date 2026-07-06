---
name: fakeapp
description: >-
  Turn a decrypted iOS IPA into a debuggable Xcode project with the `fakeapp`
  CLI. Use when the user wants to debug, profile, inspect, or reverse-engineer
  a third-party iOS app; inject custom code via a dynamic framework (+load);
  run a decrypted device app on the Apple Silicon iOS Simulator without a
  certificate; or scaffold an Xcode project from an `.ipa` file.
---

# fakeapp

`fakeapp` builds a debuggable Xcode project from a **decrypted** iOS IPA. Open
the generated project in Xcode and you get full LLDB debugging, Instruments
profiling, the View Debugger, and a `+load` code-injection point — for any app,
no jailbreak required.

## When to use this skill

- "Debug / inspect / reverse this iOS app" given an `.ipa`.
- "Run this device app on the simulator" (Apple Silicon, no cert).
- "Inject code into this app" / "hook a method" / "log its network traffic".
- "Make an Xcode project from this IPA."

Only **decrypted** IPAs work (e.g. dumped with `frida-ios-dump`). App Store
binaries are encrypted and will not run.

## Requirements

- macOS with a full **Xcode** install (uses `PlistBuddy`, `codesign`, `xcodebuild`).
- The `fakeapp` command on `PATH` (`brew install andy-sheng/fakeapp/fakeapp`).
- A decrypted `.ipa`.
- For **device** builds: an Apple Development signing certificate + a device.
- For **simulator** builds: Apple Silicon Mac; no certificate needed.

## Core workflow

1. **Generate the project:**
   ```sh
   fakeapp /path/to/App.ipa
   # options:
   #   -b, --bundle-id BUNDLE_ID   signing Bundle ID (default: com.example.fakeapp.<appname>)
   #   -c, --certificate IDENTITY  e.g. "Apple Development: Name (TEAMID)"
   #   -o, --output DIR            output directory (default: current dir)
   ```
   This produces `<AppName>/<AppName>.xcodeproj` next to a `Payload/` copy of the
   app, plus a `PDebug` injection framework target.

2. **Open in Xcode**, set the Team on both the app target and the `PDebug`
   target (device builds only), pick a destination, and press Cmd+R.

3. **Run on Simulator (Apple Silicon):** select an iPhone Simulator and Cmd+R.
   The Mach-O is auto-patched to the simulator platform and ad-hoc signed — no
   certificate. **Launch by the PROJECT Bundle ID** (e.g.
   `com.example.fakeapp.<app>`), not the app's original ID, or launch fails with
   `FBSApplicationLibrary returned nil`.

## Injecting code

Edit `<AppName>/PDebug/PDebugEntry.m`. Its `+load` runs before the app's
`main()`:

```objc
+ (void)load {
    NSLog(@"Injected before main()");
    // method swizzling, network logging, behavior tweaks, etc.
}
```

## Gotchas

- **Decrypted IPAs only** — encrypted App Store apps crash on launch.
- Extensions are stripped (`PlugIns/`, `Watch/`, `Extensions/`) to simplify signing.
- The on-disk `CFBundleIdentifier` stays the template's; the original ID is
  restored at runtime by a bundle-ID hook.
- Hardware/private-capability features (camera, push, Keychain, IAP) may fail on
  the simulator; launch, UI, and local logic work.
- Install conflict with an App Store copy → change the Bundle ID with `--bundle-id`.

## Reference

- Full help: `fakeapp --help`
- Project: https://github.com/andy-sheng/fakeapp
