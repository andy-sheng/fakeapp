# iOS Fake App

A tool for creating iOS debugging projects from decrypted IPA files. Debug and profile any iOS app without jailbreak devices.

## Features

- 🚀 **One-command setup** - Create Xcode project directly from IPA file
- 📦 **Automatic extraction** - Extract and setup .app bundle automatically
- ⚙️ **Smart Info.plist** - Preserve all permissions, URL schemes, and configurations
- 🔒 **Bundle ID control** - Keep template's Bundle ID to avoid conflicts
- 🧹 **Auto cleanup** - Remove App Extensions and Watch app for easier signing
- 🔄 **MonkeyDev inspired** - Info.plist handling based on [MonkeyDev](https://github.com/AloneMonkey/MonkeyDev)

## Requirements

- macOS with Xcode
- Decrypted IPA file
- Valid code signing certificate

## Quick Start

### 1. Create Project from IPA

```sh
bin/fakeapp /path/to/your/app.ipa
```

Optional signing settings:

```sh
bin/fakeapp --bundle-id com.example.fake.myapp \
  --certificate "Apple Development: Your Name (TEAMID)" \
  /path/to/your/app.ipa
```

If `--bundle-id` is omitted, FakeApp generates one from the app name using
`com.example.fakeapp.<appname>`. The original IPA Bundle ID is still stored for
runtime hooks in `PDebug`.

**Example:**
```sh
bin/fakeapp ~/Downloads/MyApp.ipa
```

This will:
- Extract `MyApp.app` from IPA
- Create `MyApp/` Xcode project
- Copy app to `MyApp/Payload/`
- Merge Info.plist settings
- Remove PlugIns and Watch directories

### 2. Configure Code Signing

1. Open `MyApp.xcodeproj`
2. Select both targets: `MyApp` and `PDebug`
3. Set **Team** and **Provisioning Profile** in Build Settings

### 3. Run & Debug

Build and run! All Xcode debugging features work:
- Breakpoints
- LLDB console
- Memory graph
- Instruments
- Location simulation

## Run on Simulator (Apple Silicon, no certificate)

The generated project can also run a decrypted device app **on the iOS Simulator** —
no Apple Developer certificate and no physical device required.

1. In Xcode, select an **iPhone Simulator** destination
2. Press **Cmd+R**

That's it. Behind the scenes, when the build targets `iphonesimulator` the build phase
rewrites every Mach-O (the main executable plus all bundled frameworks) from the iOS
device platform to the simulator platform and re-signs them ad-hoc. PDebug injection and
LLDB debugging keep working exactly as on device.

Command-line equivalent:

```bash
xcodebuild -project App.xcodeproj -scheme App \
  -sdk iphonesimulator -arch arm64 -derivedDataPath build build

APP=build/Build/Products/Debug-iphonesimulator/App.app
BID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")
xcrun simctl install booted "$APP"
xcrun simctl launch  booted "$BID"   # launch by the PROJECT bundle id, not the original app's
```

**Notes / limitations**
- **Apple Silicon Mac only** — the simulator runs arm64; Intel Macs (x86_64 simulator) can't run device arm64 binaries.
- **Launch by the project Bundle ID** (e.g. `com.example.fakeapp.app`), not the app's original ID.
  The on-disk `CFBundleIdentifier` is the template's; the original ID is restored at runtime by `BundleIDHook`.
- **Launching ≠ everything works.** Features that need real hardware or private capabilities
  (camera, RTC/audio-video, push, Keychain, IAP) will fail when exercised; login / UI / local
  logic debug fine.
- Mechanism is based on [arm64-to-sim](https://github.com/bogo/arm64-to-sim)
  (`scripts/arm64-to-sim` + `scripts/patch_sim.sh`).

## Code Injection

Inject custom code via `PDebug.framework`:

**File:** `[AppName]/PDebug/PDebugEntry.m`

```objc
@implementation PDebugEntry

+(void)load
{
    NSLog(@"PDebug loaded!");
    // Your code here
}

@end
```

## Info.plist Processing

### Preserved from IPA:
- Privacy permissions (Camera, Location, etc.)
- URL Schemes
- App Transport Security
- Background modes
- Interface orientations
- All custom configurations

### Modified:
- Bundle ID (uses template's configurable ID)
- Icon references

### Removed:
- PlugIns directory (App Extensions)
- Watch directory
- UISupportedDevices

## Troubleshooting

### "No .app bundle found in IPA"
- Ensure IPA is valid and contains `Payload/*.app`
- Only decrypted IPA files are supported

### Install conflict error
- Uninstall existing app from device, or
- Change Bundle ID in Build Settings to unique value

### Code signing fails
- Verify both `[AppName]` and `PDebug` targets have valid signing setup

## Advanced

### Custom Bundle ID
Change in Build Settings → Product Bundle Identifier to run alongside App Store version.

## Build System

The project uses a build script to package everything into a single executable.

### How it works

The `build.sh` script:
1. Compresses `fakesample/` template directory into `.tgz`
2. Encodes the archive as base64
3. Embeds the encoded data into `bin/fakeapp` executable
4. Creates a self-contained script with embedded template

**Structure:**
- `fakeapp.sh` - Main script logic (source code)
- `fakesample/` - Xcode project template
- `bin/fakeapp` - Compiled executable (script + embedded template)

### Build from source

After modifying `fakeapp.sh` or `fakesample/` template:

```sh
./build.sh
```

This regenerates `bin/fakeapp` with your changes.

**Example workflow:**
1. Edit `fakeapp.sh` to add features
2. Run `./build.sh` to rebuild
3. Test with `bin/fakeapp your-app.ipa`

### Smoke Tests

Run the fixture-based test:

```sh
tests/test_bundle_id_flow.sh
```

Run a certificate-free smoke test against a real IPA:

```sh
FAKEAPP_TEST_IPA=/path/to/app.ipa \
FAKEAPP_TEST_BUNDLE_ID=com.example.fakeapp.smoke \
tests/smoke_real_ipa_generate.sh
```

This test only verifies project generation, Bundle ID rewriting, PDebug's
original Bundle ID config, extension cleanup, and `xcodebuild -list`. It does
not build, sign, install, or require Apple certificates.

### What gets embedded

The template directory contains:
- Xcode project structure (`.xcodeproj`)
- PDebug framework for code injection
- Build scripts for code signing
- Default configurations

All of this is packaged into the single `bin/fakeapp` executable, so users only need that one file.

## Credits

Based on [MonkeyDev](https://github.com/AloneMonkey/MonkeyDev) Info.plist handling approach.

## License

MIT License
