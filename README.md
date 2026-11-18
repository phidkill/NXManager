# NXManager

NXManager is a native SwiftUI game library and builder for NXNative on Apple Silicon Macs. It imports XCI, NSP, NSZ, XCZ, and NUP packages without moving the originals; builds Mac game apps; and organizes compiled apps, artwork, controller profiles, and game data.

## Get the prebuilt app

The repository includes a packaged native build at `dist/NXManager-macOS.zip`. From the repository root, extract it into Downloads:

```bash
ditto -x -k dist/NXManager-macOS.zip ~/Downloads
open ~/Downloads/NXManager.app
```

You can move `NXManager.app` to `/Applications` in Finder. The archive is not notarized; if macOS blocks the first launch, Control-click the app, choose **Open**, then confirm.

## Build NXManager from source

Build on an Apple Silicon Mac with Xcode and its command-line tools selected:

```bash
./build_macos.sh
```

The native app is written in SwiftUI and has a macOS 14 deployment target. The build produces `dist/NXManager.app`.

## First-launch setup and NXNative tools

The current setup wizard checks for Xcode and Python, helps select `prod.keys`, clones NXNative, and can prepare the isolated Python environment and modules needed by the engine. Switch 1 builds require a readable `prod.keys`; Switch 2 NUP builds do not.

A complete, guided initializer for the full NXNative toolchain is planned. It will cover the required Python runtime, Xcode and Metal toolchain, and supporting tools such as Homebrew, Git, XcodeGen, zstd, glslang, and .NET. The current app does not install Xcode, Metal, Homebrew, or those system tools automatically; install them using the upstream instructions before building games. The exact requirements can change, so check [NXNative's README](https://github.com/seedds/nxnative) before setting up a machine.

For current NXNative builds, the upstream project requires macOS 26.6 or later, Xcode 27.2, and Python 3.12 or later for the game-building toolchain. These game-build requirements are separate from running the NXManager interface.

## Library data

NXManager stores its library and preferences under:

```text
~/Library/Application Support/NXManager/
├── library.json
├── Data/
│   ├── PackageLinks/<game-id>/
│   ├── Builds/<game-id>/
│   ├── Covers/
│   └── Artwork/
└── Engine/
    ├── nxnative/
    └── PythonEnvironment/
```

Package files stay at their original paths; NXManager keeps links to them. NXNative's own saves, settings, screenshots, and logs remain in the locations documented by NXNative. Built apps are stored in the selected output folder and can be opened from Finder.

## Artwork and package identification

Choose custom cover art in Game Details, or use the icon from the latest built game app as the cover without rebuilding. App icons are enlarged to fill the same square artwork area as cover images; custom covers keep their full-frame presentation.

For Switch 1 packages, NXManager reads Title ID and version from common filename markers such as `[0100...][v0]`; NXNative performs the authoritative package analysis during its build. For Switch 2, select a `.nup` file directly or import a folder containing exactly one `.nup` file. NXNative reads the title metadata from the NUP container. After a successful build, NXManager also reads the Title ID from the generated app's `Info.plist` to enable save-folder shortcuts and online artwork lookup.

The library can look up banner artwork online by Title ID. Artwork lookup is optional and requires network access.

## Controllers

The native controller setup can calibrate buttons, D-pad directions, and stick axes. Profiles are stored in NXManager. For raw HID controllers, the app can read and write the documented `DM_HID_MAP` and `DM_HID_LOG` settings in NXNative's per-game `env.txt`. The documented remapping covers the four face buttons; NXNative does not currently document stick-axis remapping through this interface.

## Build flow

NXManager runs NXNative's `scripts/build_ipa_from_nsp.py` with `--platform mac-app`, JSON progress reporting, a per-game work directory, and the selected output path. It passes `-k` for Switch 1 packages and omits it for NUP containers. The app verifies the process exit status and the generated `.app`. If cancellation does not stop the process within five seconds, NXManager force-stops it.

When NXNative has no countable progress fraction, the progress bar remains indeterminate. NXManager retains the latest build log for each game; NXNative also maintains its own build logs.

## Tests

Run the native unit checks with:

```bash
./tests/run_native_unit_tests.sh
```

These checks cover Title ID validation, library status, HID configuration, and controller profile helpers. The macOS UI, physical controller behavior, engine installation, and real game builds still need on-device integration testing.

## Upstream references

- [NXNative](https://github.com/seedds/nxnative)
- [Frontend integration](https://github.com/seedds/nxnative/blob/main/docs/frontends.md)
- [Build script](https://github.com/seedds/nxnative/blob/main/scripts/build_ipa_from_nsp.py)

NXManager is an independent front end and is not affiliated with Nintendo or the NXNative maintainers.
