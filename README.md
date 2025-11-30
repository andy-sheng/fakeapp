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

**Example:**
```sh
bin/fakeapp ~/Downloads/WeChat.ipa
```

This will:
- Extract `WeChat.app` from IPA
- Create `WeChat/` Xcode project
- Copy app to `WeChat/Payload/`
- Merge Info.plist settings
- Remove PlugIns and Watch directories

### 2. Configure Code Signing

1. Open `WeChat.xcodeproj`
2. Select both targets: `WeChat` and `PDebug`
3. Set **Team** and **Provisioning Profile** in Build Settings

### 3. Run & Debug

Build and run! All Xcode debugging features work:
- Breakpoints
- LLDB console
- Memory graph
- Instruments
- Location simulation

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
