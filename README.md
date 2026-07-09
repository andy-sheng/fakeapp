# iOS Fake App

A tool for creating iOS debugging projects from decrypted IPA files. Debug and profile any iOS app without jailbreak devices.

## Features

- 🚀 **One-command setup** - Create Xcode project directly from IPA file
- 📦 **Automatic extraction** - Extract and setup .app bundle automatically
- ⚙️ **Smart Info.plist** - Preserve all permissions, URL schemes, and configurations
- 🔒 **Bundle ID control** - Keep template's Bundle ID to avoid conflicts
- 🧹 **Auto cleanup** - Remove App Extensions and Watch app for easier signing
- 🔤 **ObjC symbol restoration** - Rebuild `-[Class method]` names into the stripped binary so backtraces are readable ([details](#objective-c-symbol-restoration))
- 📱 **Simulator support** - Run a decrypted device app on the Apple Silicon iOS Simulator, no certificate ([details](#run-on-simulator-apple-silicon-no-certificate))
- 🔄 **MonkeyDev inspired** - Info.plist handling based on [MonkeyDev](https://github.com/AloneMonkey/MonkeyDev)

## Requirements

- macOS with Xcode
- Decrypted IPA file
- Valid code signing certificate

## Install

### Homebrew (recommended)

Once a tap is published (see [Releasing](#releasing)):

```sh
brew install andy-sheng/fakeapp/fakeapp
# or, equivalently:
brew tap andy-sheng/fakeapp
brew install fakeapp
```

Try the latest commit without a release (no tap repo required):

```sh
brew install --HEAD https://raw.githubusercontent.com/andy-sheng/fakeapp/master/Formula/fakeapp.rb
```

Homebrew rebuilds `bin/fakeapp` from source during install, so the embedded
template always matches the version you install. After installing, the `fakeapp`
command is on your `PATH`:

```sh
fakeapp ~/Downloads/MyApp.ipa
```

> macOS only — the tool relies on `PlistBuddy`, `codesign`, and `xcodebuild`.
> Run `xcode-select --install` if the command line tools are missing.

### From source (no Homebrew)

Clone the repo and run the bundled executable directly:

```sh
git clone https://github.com/andy-sheng/fakeapp.git
fakeapp/bin/fakeapp ~/Downloads/MyApp.ipa
```

### Agent skill

fakeapp ships a bundled [agent skill](skills/fakeapp/SKILL.md) that teaches an AI
coding client (Claude Code, Codex, Cursor, …) when and how to drive the tool.
Install it into your client's skill directory:

```sh
fakeapp skill                        # auto-detect installed clients
fakeapp skill --client claude        # a single client
fakeapp skill --client claude,codex  # several clients
fakeapp skill --client all --force   # (re)install everywhere
fakeapp skill --dest ~/.config/skills
fakeapp skill --print                # inspect the skill content
fakeapp skill --uninstall            # remove it again
```

With no `--client`, it installs into every supported client detected on this
machine (falling back to Claude Code if none are found). Supported clients and
their targets:

| Client | Skill installed to |
| --- | --- |
| `claude` (Claude Code) | `~/.claude/skills/fakeapp` |
| `codex` (Codex CLI) | `~/.codex/skills/fakeapp` |
| `cursor` (Cursor) | `~/.cursor/skills/fakeapp` |
| `agents` (Agent Skills) | `~/.agents/skills/fakeapp` |

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
- Restore Objective-C symbols into the main binary (pass `--no-symbols` to skip)

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

## Objective-C Symbol Restoration

A decrypted app's main executable is stripped, so Xcode/LLDB backtraces normally show
`AppName`​`` ___lldb_unnamed_symbol$$0x...`` instead of real method names. When creating the
project, FakeApp parses the executable's Objective-C metadata and writes
`-[Class method]` / `+[Class method]` entries back into its symbol table, so backtraces,
Instruments, and `atos` all show readable names.

- Runs **once** at project-generation time, baked into `Payload/<App>.app`. Xcode re-signs
  on build, so the modified binary is fine.
- **On by default.** Disable with `--no-symbols` or `FAKEAPP_NO_SYMBOLS=1`.
- Restores **Objective-C** methods (real `-[Class method]` names) **and Swift class methods**
  (synthetic `Type.method<N>` names from `__swift5` metadata — Swift doesn't store method
  names, so the type name is real but the method part is kind + vtable index). Only the
  **main executable** is processed; C/C++ static functions and generic-Swift stay unnamed.
- Non-fatal: if the binary can't be processed, generation continues without symbols.

```sh
bin/fakeapp app.ipa               # symbols restored (default)
bin/fakeapp --no-symbols app.ipa  # skip symbol restoration
```

Powered by [restore-symbol](https://github.com/andy-sheng/restore-symbol) (a fork whose
class-dump handles modern *relative method lists*); the bundled binary is rebuilt by
`scripts/build-restore-symbol.sh`.

## Run on Simulator (Apple Silicon, no certificate)

The generated project can also run a decrypted device app **on the iOS Simulator** —
no Apple Developer certificate and no physical device required.

1. In Xcode, select an **iPhone Simulator** destination
2. Press **Cmd+R**

That's it. Behind the scenes, when the build targets `iphonesimulator` the build phase
rewrites every Mach-O (the main executable plus all bundled frameworks) from the iOS
device platform to the simulator platform and re-signs them ad-hoc. PDebug injection and
LLDB debugging keep working exactly as on device. [LookinServer](https://github.com/QMUI/LookinServer)
ships as an xcframework with an arm64-simulator slice, so live UI inspection works on the
simulator too.

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

The `skills/` directory (the `fakeapp` agent skill) is embedded the same way and
unpacked by `fakeapp skill`.

All of this is packaged into the single `bin/fakeapp` executable, so users only need that one file.

## Releasing

The Homebrew formula lives at [`Formula/fakeapp.rb`](Formula/fakeapp.rb) and builds
`bin/fakeapp` from source on install. Cutting a release is one command:

```sh
scripts/brew-release.sh 1.0.0   # first release; matches the committed VERSION
```

This bumps `VERSION`, creates and pushes the `v1.0.0` git tag, downloads the
GitHub source tarball for that tag, computes its `sha256`, rewrites `url`/`sha256`
in the formula, and commits the change. Use `--no-push` to stage everything
locally first, or `-y` to skip the confirmation prompt.

### Publishing the Homebrew tap

`brew install andy-sheng/fakeapp/fakeapp` resolves to a tap repo named
`homebrew-fakeapp`. Create it once:

```sh
# In a sibling directory
mkdir -p homebrew-fakeapp/Formula
cp fakeapp/Formula/fakeapp.rb homebrew-fakeapp/Formula/
cd homebrew-fakeapp
git init && git add . && git commit -m "fakeapp formula"
# create the GitHub repo `andy-sheng/homebrew-fakeapp`, then:
git remote add origin git@github.com:andy-sheng/homebrew-fakeapp.git
git push -u origin main
```

After that, point the release script at your tap checkout so each release also
updates the published formula:

```sh
scripts/brew-release.sh 1.0.1 --tap-dir ../homebrew-fakeapp   # subsequent releases
```

Users then upgrade with `brew update && brew upgrade fakeapp`.

## Credits

Based on [MonkeyDev](https://github.com/AloneMonkey/MonkeyDev) Info.plist handling approach.

## License

MIT License
