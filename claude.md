# iOS Fake App - Project Documentation

## Project Overview

**iOS Fake App** is a reverse engineering tool that creates debuggable Xcode projects from decrypted iOS IPA files. It enables developers to debug, profile, and analyze any iOS application without requiring jailbroken devices.

### Purpose
- Debug third-party iOS apps using Xcode's full debugging capabilities
- Inject custom code into apps via dynamic framework
- Analyze app behavior, network traffic, and internal logic
- Learn from other apps' implementations

## Architecture

### Core Components

```
fakeapp-andysheng/
├── bin/fakeapp              # Self-contained executable (script + embedded template)
├── fakeapp.sh               # Main script source code
├── build.sh                 # Build system to generate bin/fakeapp
├── fakesample/              # Xcode project template
│   ├── Payload/             # Destination for extracted .app bundle
│   ├── PDebug/              # Code injection framework
│   ├── fakesample.xcodeproj # Xcode project template
│   └── scripts/             # Build phase scripts (resign, etc.)
└── README.md                # User documentation
```

### Build System Flow

```
┌─────────────┐
│ fakeapp.sh  │ ──┐
└─────────────┘   │
                  │  build.sh
┌─────────────┐   │  ========>  ┌──────────────┐
│ fakesample/ │ ──┘             │ bin/fakeapp  │
└─────────────┘                 └──────────────┘
     (tar + base64 embedded)
```

**build.sh process:**
1. Compress `fakesample/` → `fakesample.tgz`
2. Base64 encode the archive
3. Copy `fakeapp.sh` to `bin/fakeapp`
4. Append encoded data to `bin/fakeapp`
5. Append `main;` to execute on run

## Main Script (fakeapp.sh)

### Function Flow

```
main()
  ├─> extract_ipa()           # Extract IPA and find .app bundle
  ├─> prepare_packed_files()  # Unpack embedded fakesample.tgz
  ├─> replace_files()          # Rename template files (fakesample → appname)
  ├─> copy_app_to_payload()   # Copy .app to Payload/ and cleanup
  │     ├─> Remove PlugIns/   # Delete App Extensions
  │     └─> Remove Watch/     # Delete Watch app
  ├─> update_info_plist()     # Merge Info.plist from IPA
  │     ├─> Save original Bundle ID
  │     ├─> Copy/Merge IPA's Info.plist
  │     ├─> Restore Bundle ID
  │     ├─> Delete UISupportedDevices
  │     └─> Update CFBundleIconFiles
  └─> migrate_target()        # Move project to current directory
```

### Key Functions

#### 1. `extract_ipa()`
- Extracts IPA file using `unzip -o -q`
- Validates Payload directory exists
- Finds `.app` bundle (must be directory, not file)
- Extracts app name from bundle name
- Sets environment variables: `EXTRACTED_APP_PATH`, `EXTRACTED_INFO_PLIST`, `appname`

**Validations:**
- IPA file must exist
- Must contain Payload directory
- Must contain valid .app bundle (directory)
- Prompts if destination directory already exists

#### 2. `prepare_packed_files()`
- Base64 decodes embedded `fakesample_package` variable
- Extracts template to temporary directory
- Template contains complete Xcode project structure

#### 3. `replace_files()`
- Recursively processes all files in template
- Replaces string "fakesample" with actual app name
- Renames files containing "fakesample" in filename
- Uses `sed` for content replacement
- Processes in reverse order (deepest first) for safe renaming

#### 4. `copy_app_to_payload()`
- Copies extracted `.app` bundle to `Payload/` directory
- Removes `PlugIns/` (App Extensions - widgets, share extensions, etc.)
- Removes `Watch/` (Apple Watch companion app)
- Removes `Extensions/` (Additional app extensions)

**Why remove these:**
- Simplifies code signing (extensions need separate entitlements)
- Reduces app size
- Avoids extension-related crashes

#### 5. `update_info_plist()`
**MonkeyDev-inspired logic:**

```bash
# Save original Bundle ID
original_bundle_id = template's CFBundleIdentifier

# Decision logic
if (template_executable != ipa_executable):
    # Different apps - full copy
    cp ipa_info_plist → project_info_plist
else:
    # Same app - merge keys
    PlistBuddy Merge ipa_info_plist → project_info_plist

# Restore original Bundle ID
Set CFBundleIdentifier = original_bundle_id

# Cleanup
Delete UISupportedDevices
Update CFBundleIconFiles → point to template icon
```

**Preserved from IPA:**
- All privacy permissions (NSCameraUsageDescription, NSLocationWhenInUseUsageDescription, etc.)
- URL Schemes (CFBundleURLTypes)
- App Transport Security (NSAppTransportSecurity)
- Background modes (UIBackgroundModes)
- Interface orientations (UISupportedInterfaceOrientations)
- Device capabilities (UIRequiredDeviceCapabilities)
- All custom keys

**Modified:**
- `CFBundleIdentifier` - Restored to template's value (allows customization in Xcode)
- `CFBundleIconFiles` - Points to `[appname]/icon.png`

**Removed:**
- `UISupportedDevices` - Device restrictions that may cause compatibility issues

## Template Structure (fakesample/)

### Targets

**1. Main App Target (fakesample → renamed to app name)**
- Runs the actual app from `Payload/[AppName].app`
- Build phase copies app and runs resign script
- Links PDebug.framework for code injection

**2. PDebug Target**
- Dynamic framework injected into main app
- Entry point: `PDebugEntry.m +load` method
- Executes before app's `main()` function
- Use cases:
  - Method swizzling
  - Network monitoring
  - Behavior modification
  - Logging and debugging

### Build Phases

**Main app "Run Script" phase:**
```bash
bash "$SRCROOT/scripts/replace_app.sh"
```

This script:
- Removes old app bundle
- Copies from `Payload/` to build location
- Removes embedded.mobileprovision
- Makes executable executable
- Runs resign script for frameworks/dylibs

## Technical Details

### Info.plist Merge Strategy

Uses `PlistBuddy` command-line tool:
```bash
# Full merge of all keys
/usr/libexec/PlistBuddy -c "Merge 'source.plist'" "target.plist"

# Individual key operations
/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.new.id" "Info.plist"
/usr/libexec/PlistBuddy -c "Delete :UISupportedDevices" "Info.plist"
```

### File Replacement Algorithm

```bash
find $template -type f | sort -r | while read file; do
    # Replace content
    sed -i.bak "s/fakesample/$appname/g" "$file"

    # Rename file if needed
    if [[ $filename == *fakesample* ]]; then
        mv "$file" "${file/fakesample/$appname}"
    fi
done
```

**Why reverse order (`sort -r`):**
- Processes deepest files first
- Prevents path invalidation when renaming directories
- Example: Rename `/a/b/file.txt` before renaming `/a/b/` directory

### Error Handling

**IPA Extraction:**
- Checks unzip return code
- Validates Payload directory exists
- Ensures .app bundle is directory (not file)
- Uses `-type d` in find to avoid false positives

**User Confirmations:**
- Prompts before overwriting existing project directory
- Allows cancellation (exits with code 1)

**Silent Failures:**
- `|| true` on PlugIns/Watch removal (may not exist)
- `2>/dev/null` on PlistBuddy operations (keys may not exist)

## Usage Workflow

### Developer Workflow

1. **Get decrypted IPA:**
   ```bash
   # Using frida-ios-dump or similar
   frida-ios-dump -o app.ipa com.target.app
   ```

2. **Create project:**
   ```bash
   bin/fakeapp app.ipa
   ```

3. **Configure signing:**
   - Open `App.xcodeproj`
   - Set Team and Provisioning Profile
   - Both `App` and `PDebug` targets

4. **Add injection code (optional):**
   ```objc
   // App/PDebug/PDebugEntry.m
   +(void)load {
       NSLog(@"Injected!");
       // Your code here
   }
   ```

5. **Build & Debug:**
   - Set breakpoints
   - Use LLDB
   - Profile with Instruments

### Common Use Cases

**1. API Analysis:**
```objc
// Hook NSURLSession
Method original = class_getInstanceMethod([NSURLSession class], @selector(dataTaskWithRequest:));
// Swizzle to log all requests
```

**2. UI Inspection:**
- Use Xcode's View Debugger
- Inspect view hierarchy
- Check Auto Layout constraints

**3. Behavior Modification:**
```objc
// Bypass verification checks
// Modify data before display
// Skip in-app purchases (for testing)
```

## Security & Legal Notes

### Intended Use
- Educational purposes
- Security research
- Testing your own apps
- Apps you have permission to analyze

### Not For
- Piracy or app cracking
- Distributing modified apps
- Bypassing DRM for distribution
- Violating app terms of service

### Technical Limitations
- Only works with **decrypted** IPA files
- Device must have developer certificate
- Cannot debug App Store binaries directly (encryption)
- Code injection may trigger anti-tampering checks

## Dependencies

**System Requirements:**
- macOS (tested on macOS 10.12+)
- Xcode command-line tools
- `/usr/libexec/PlistBuddy`
- Standard Unix tools: `unzip`, `tar`, `base64`, `find`, `sed`

**Runtime:**
- iOS device or simulator
- Valid code signing certificate
- Provisioning profile

## Comparison with MonkeyDev

### Similarities
- Info.plist handling logic (copy/merge strategy)
- Code injection via dynamic framework
- Removal of PlugIns, Watch, and Extensions

### Differences
- **MonkeyDev:** Full-featured template with extensive tweaks
- **FakeApp:** Lightweight, focused on quick debugging setup
- **MonkeyDev:** CydiaSubstrate integration
- **FakeApp:** Simple +load injection point

## Development

### Modifying the Script

1. Edit `fakeapp.sh`
2. Test changes:
   ```bash
   ./fakeapp.sh test.ipa
   ```
3. Rebuild executable:
   ```bash
   ./build.sh
   ```
4. Test final binary:
   ```bash
   bin/fakeapp test.ipa
   ```

### Modifying the Template

1. Edit files in `fakesample/`
2. Update Xcode project settings
3. Rebuild:
   ```bash
   ./build.sh
   ```

**Important:** After rebuilding, the template is embedded, so changes to `fakesample/` won't affect existing generated projects.

## Troubleshooting Guide

### "No .app bundle found"
- **Cause:** Invalid IPA or non-app content
- **Solution:** Verify IPA contains `Payload/*.app` directory

### "Install conflict"
- **Cause:** App Store version installed with same Bundle ID
- **Solution:**
  - Uninstall existing app, or
  - Change Bundle ID in Build Settings

### Code signing errors
- **Cause:** Missing certificates/profiles
- **Solution:**
  - Install development certificate
  - Create/download provisioning profile
  - Configure in Xcode signing settings

### App crashes on launch
- **Possible causes:**
  - Missing frameworks
  - Entitlements mismatch
  - Anti-tampering detection
- **Debug:**
  - Check console logs
  - Use lldb to find crash point
  - Verify all frameworks are signed

## Future Enhancements

Potential improvements:
- [ ] GUI version (drag & drop IPA)
- [ ] Automatic certificate detection
- [ ] Framework dependency analysis
- [ ] Anti-anti-debugging helpers
- [ ] Batch processing multiple IPAs
- [ ] Swift integration templates

## References

- [MonkeyDev](https://github.com/AloneMonkey/MonkeyDev) - Info.plist handling inspiration
- [frida-ios-dump](https://github.com/AloneMonkey/frida-ios-dump) - IPA decryption
- [iOS App Reverse Engineering](https://github.com/iosre/iOSAppReverseEngineering) - General RE knowledge

## Version History

- **2025-11-30**: Major refactor to support IPA input, Info.plist merging
- **2016-07-02**: Original version (manual app name input)

## License

MIT License - See LICENSE file for details.
