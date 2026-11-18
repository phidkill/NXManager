# NXManager

NXManager includes a native SwiftUI app for macOS and an earlier Python + PySide6 front end. The native app is the recommended interface. Both keep game packages at their original locations and store their own catalogue under `~/Library/Application Support/NXManager/`; the catalogues are separate and are not synchronized.

## Native macOS app

The SwiftUI interface has a horizontal game-poster carousel, dashed click-or-drop zones for base packages and updates, and a library for source packages and compiled Mac apps. Selecting a compiled app adds it immediately when its `Info.plist` has NXNative's 16-digit `DMTitleID` and the app executable is present. Choose custom cover art in Game Details, launch an app from its poster, or remove its library entry without deleting the app itself. Game Details and the Games context menu open NXNative's per-game `save/` folder. Source packages are linked instead of copied, and builds run in the background while NXManager follows NXNative's JSON progress events.

Build the native app on an Apple Silicon Mac with Xcode and its command-line tools selected:

```bash
./build_macos.sh
```

The result is `dist/NXManager.app`. Open it from Finder. Building games requires NXNative's current dependencies, including Python 3.12+, macOS 26.6 or later, Xcode 27.2, and the tools listed by the upstream project. NXManager does not bundle or install system dependencies. Choose **Settings → Install NXNative** to clone the engine; the app prepares an isolated Python environment and installs NXNative's Python packages when you start the first build. Switch 1 packages need a readable `prod.keys`; Switch 2 `.nup` containers do not. Check the upstream README for current requirements.

### Get the prebuilt app

The repository includes a packaged native build at `dist/NXManager-macOS.zip`. From the repository root, extract it into Downloads:

```bash
ditto -x -k dist/NXManager-macOS.zip ~/Downloads
open ~/Downloads/NXManager.app
```

You can move `NXManager.app` to `/Applications` in Finder. The archive is not notarized; if macOS blocks the first launch, Control-click the app, choose **Open**, then confirm.

The native interface includes controller calibration and retains the latest build status and log for each game, but it does not yet provide the Python edition's multi-build history view. Its library, preferences and engine checkout use the native app's own data store; existing data in the earlier SQLite catalogue is not migrated automatically. The library can look up banner artwork online by Title ID; artwork lookup is optional and requires network access.

## Earlier Python interface

The Python + PySide6 front end remains available as an earlier edition. Its UI contains Games / Controllers / Import pages, SQLite persistence, controller calibration storage, and the workflows documented below.

> **Earlier edition, source release 0.1.0.** The application shell, Games / Controllers / Import pages, SQLite persistence, package registration, engine clone/update workflow, JSON build monitor, build history, screenshots folder access, themes, and controller calibration storage are implemented. The Python edition's packaged `.app` and hardware workflows still need validation on the target Mac.

## Requirements

- Apple Silicon Mac
- Python 3.12 or newer (ARM64)
- macOS 26.6 or later and Xcode 27.2 for current NX Native builds, as stated in the upstream README
- Homebrew, Git, XcodeGen, zstd and glslang as required by NX Native
- PySide6
- Optional native controller support: PyObjC `Cocoa` and `GameController` frameworks

NXManager does not install system dependencies silently. Use Settings → Diagnostic système to inspect the machine. The current NX Native requirements and build protocol can change; check the upstream documentation before building.

## Run from source

```bash
# Run these commands from the repository root.
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -e '.[macos]'
python -m nxmanager.main
```

If the `macos` optional dependencies are unavailable, the rest of the UI can still open, but native controller discovery will report as unavailable.

## Build a macOS application

```bash
./build_python_macos.sh
```

The script creates `dist/NXManager.app` using PyInstaller. It checks for Python 3.12+ ARM64 and must be run on macOS; a Linux environment cannot produce or validate a native macOS application bundle. Test launching from Finder on the target Mac before distributing it.

## Data layout

The Python and native editions use separate catalogues. They do not migrate or synchronize game records. Their default `PackageLinks/`, `Builds/`, and `Engine/nxnative/` locations overlap, so they can reuse the same package links, build work folders, and engine checkout.

### Earlier Python edition

```text
~/Library/Application Support/NXManager/
├── Data/
│   ├── nxmanager.sqlite3
│   ├── PackageLinks/<game-id>/   # symlinks to original package files
│   ├── Builds/<game-id>/         # NX Native work/cache folder
│   └── Covers/
├── Engine/nxnative/              # managed upstream checkout (or user-selected checkout)
├── Logs/
└── Backups/
```

### Native SwiftUI edition

```text
~/Library/Application Support/NXManager/
├── library.json
├── Data/
│   ├── PackageLinks/<game-id>/
│   ├── Builds/<game-id>/
│   ├── Covers/
│   └── Artwork/
├── Engine/nxnative/
└── Engine/PythonEnvironment/
```

NX Native's own per-game saves, settings, screenshots and logs remain in the locations documented by NX Native, not copied into NXManager.

## Earlier Python edition: controller calibration limitation

The Controllers page uses Apple's GameController framework (through PyObjC) to detect standard controller elements and guide a button / D-pad / stick calibration. Profiles can be stored globally or associated with a game and a detected device.

NX Native also documents `DM_HID_MAP`, `DM_HID_LOG` and per-game `env.txt` for raw HID controllers that macOS does not expose through GameController (for example, some 8BitDo modes). The UI can enable `DM_HID_LOG=1` and write the documented face-button mapping `DM_HID_MAP=A=...,B=...,X=...,Y=...` to `~/Library/Application Support/nxnative/<TITLE_ID>/env.txt`, preserving unrelated settings. The numeric codes must be read from the game's NX Native log and entered by the user. This is intentionally not applied to controllers already handled by Apple's GameController framework: NX Native's documentation says those use the native controller path, not this raw-HID remap.

The calibration wizard's GameController result is a record of standardized logical elements macOS reports, not raw USB HID usages. It is saved as an NXManager profile and is not automatically converted into `DM_HID_MAP`. The currently documented `DM_HID_MAP` example remaps only the four face buttons; the documentation does not define a stick-axis remap. This avoids silently applying a mapping to the wrong controller path or claiming unsupported stick remapping.

## Package identification

The native importer accepts `.XCI`, `.NSP`, `.NSZ`, `.XCZ` and `.NUP` case-insensitively. For Switch 2, select a `.nup` file directly or import a folder containing exactly one `.nup` file; NXNative reads the title metadata from the container and builds it without `prod.keys`. NUP folders cannot be mixed with Switch 1 packages. Before the first successful NUP build, NXManager does not know the container's Title ID, so its save-folder shortcut and automatic Title-ID artwork lookup are unavailable. After the build, NXManager reads the Title ID from the generated app's `Info.plist` and enables those features. For other package types NXManager reads Title ID and version from common filename markers such as `[0100...][v0]`; NXNative performs the authoritative package analysis during its build.

## Build flow

Both editions invoke the upstream `scripts/build_ipa_from_nsp.py` with `--platform mac-app`, `--progress json`, `--work-dir`, and `-o`. They pass `-k` for Switch 1 packages and omit it for NUP containers. They parse JSON progress events, check the process exit code, and verify the requested `.app` output. Cancelling sends a termination signal; the native edition force-stops the process if it has not exited after five seconds.

The app does not fabricate percentages: when the engine reports no countable fraction, the progress bar remains indeterminate. The Python edition writes detailed logs under `Logs/`; the native edition retains the latest build log in `library.json`. NXNative also keeps its own build logs.

## Tests

```bash
python -m pytest
python -m compileall -q nxmanager
./tests/run_native_unit_tests.sh
```

Install the Python test dependency with `python -m pip install -e '.[test]'`. Python unit tests cover package parsing, database operations, stale package-link replacement, and per-game environment configuration. The Swift unit test script covers Title ID validation, library status, HID configuration, and controller profile helpers. The macOS UI, physical controller behavior, engine installation/update, and real game builds still need on-device integration tests.

## Upstream references

- https://github.com/seedds/nxnative
- https://github.com/seedds/nxnative/blob/main/docs/frontends.md
- https://github.com/seedds/nxnative/blob/main/scripts/build_ipa_from_nsp.py

NXManager is an independent front end and is not affiliated with Nintendo or the NX Native maintainers.
