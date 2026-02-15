# FileRedirectDylib

A dylib for iOS that hooks file-access functions so games like **Bully** or **GTA San Andreas** transparently load modded files from `Documents/disk/` instead of the app bundle.

## How It Works

On non-jailbroken iOS the `.app` bundle is **read-only**. This dylib doesn't try to write into it. Instead it:

1. Hooks C functions: `fopen`, `open`, `stat`, `access`
2. Swizzles ObjC methods: `NSBundle -pathForResource:ofType:`, `NSFileManager -contentsAtPath:`
3. When the game requests a file from its `.app` bundle, the hook checks if a replacement exists at `Documents/disk/<same relative path>`
4. If yes → returns the modded file. If no → falls through to the original.

## File Structure

```
FileRedirectDylib/
├── .github/
│   └── workflows/
│       └── build.yml  ← GitHub Actions CI (builds on free macOS runner)
├── tweak.m            ← Main hook/swizzle logic
├── fishhook.h         ← Facebook fishhook header
├── fishhook.c         ← Facebook fishhook implementation
├── Makefile           ← Build script
└── README.md          ← This file
```

## Building — No Mac Required (GitHub Actions)

You do NOT need a Mac. GitHub gives you a free macOS build machine.

### Step-by-step:

1. **Create a GitHub account** if you don't have one: https://github.com
2. **Create a new repository** (e.g. `FileRedirectDylib`)
3. **Upload all files** from this folder to the repo, keeping the folder structure
   (make sure `.github/workflows/build.yml` is included)
4. **Push / commit** — the build runs automatically
5. Go to the **Actions** tab in your repo
6. Click the latest workflow run → click **FileRedirect-dylib** under "Artifacts"
7. **Download the zip** — it contains `FileRedirect.dylib` ready to inject

You can also trigger a build manually: Actions tab → "Build FileRedirect.dylib" → "Run workflow".

### Alternative: Build locally on macOS

If you do have access to a Mac:

```bash
cd FileRedirectDylib
make
```

This produces `FileRedirect.dylib` targeting iOS arm64 (min iOS 12.0).

**Requirements:**
- macOS with Xcode or Xcode Command Line Tools
- iOS SDK (included with Xcode)

## Injecting into an IPA

### Option A: Using insert_dylib

```bash
# 1. Unzip the IPA
mkdir payload && cd payload
unzip ../GameName.ipa

# 2. Copy dylib into the .app
cp FileRedirect.dylib Payload/GameName.app/

# 3. Inject the load command
insert_dylib --strip-codesig --inplace \
  @executable_path/FileRedirect.dylib \
  Payload/GameName.app/GameName

# 4. Re-zip as IPA
zip -r ../GameName-modded.ipa Payload/
```

### Option B: Using optool

```bash
optool install -c load -p @executable_path/FileRedirect.dylib \
  -t Payload/GameName.app/GameName
```

## Re-signing & Sideloading

After injection, the IPA needs to be re-signed:

- **iOS App Signer** (macOS GUI) — easiest option
- **ldid** — `ldid -S Payload/GameName.app/GameName`
- **codesign** — `codesign -f -s "Apple Development: you@email.com" Payload/GameName.app`

Then sideload with:
- **AltStore** / **Sideloadly** / **TrollStore** (if available)

## Using Mods

1. Install the modded IPA on your device
2. Open a file manager (e.g. Files app, or via iTunes File Sharing)
3. Navigate to the app's `Documents/` folder
4. Create a `disk/` subfolder if it doesn't exist (the dylib also auto-creates it)
5. Place your modded files inside `disk/`, mirroring the `.app` bundle structure

### Example for GTA SA

If the original file is at:
```
GameName.app/texdb/gta3.txd
```

Place your modded version at:
```
Documents/disk/texdb/gta3.txd
```

The dylib will intercept the read and serve your file instead.

## Debugging

The dylib logs all redirected file accesses to the device console. View them with:

```bash
# Via Xcode → Window → Devices and Simulators → Open Console
# Or via idevicesyslog:
idevicesyslog | grep "FileRedirect"
```

Look for lines like:
```
[FileRedirect] fopen: /var/containers/.../MyApp.app/data/file.dat -> /var/containers/.../Documents/disk/data/file.dat
```

To disable logging in production, set `REDIRECT_LOG_ENABLED` to `0` in `tweak.m`.

## Notes

- This works on **non-jailbroken** iOS via sideloading
- The `.app` bundle is never modified at runtime — all redirection is in-memory
- If a file is NOT in `Documents/disk/`, the original bundle file is used (no breakage)
- Compatible with **Bully**, **GTA San Andreas**, **GTA III**, **GTA Vice City**, **Max Payne**, and other Rockstar iOS ports
