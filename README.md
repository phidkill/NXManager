# NXManager

NXManager includes a native SwiftUI app for macOS and an earlier Python + PySide6 front end. The native app is the recommended interface. Both keep game packages at their original locations and maintain a separate library under `~/Library/Application Support/NXManager/`.

## Native macOS app

The SwiftUI interface has a horizontal game-poster carousel, dashed click-or-drop zones for base packages and updates, and a library for source packages and compiled Mac apps. Selecting a compiled app adds it immediately when its `Info.plist` has NXNative's 16-digit `DMTitleID` and the app executable is present. Choose custom cover art in Game Details, launch an app from its poster, or remove its library entry without deleting the app itself. Game Details and the Games context menu open NXNative's per-game `save/` folder. Source packages are linked instead of copied, and builds run in the background while NXManager follows NXNative's JSON progress events.

Build the Apple Silicon app with Xcode 27 or newer:

```bash
./build_macos.sh
```

The result is `dist/NXManager.app`. Open it from Finder. NXManager itself is a small native app; building games still requires NXNative's current dependencies, including Python 3.12+, Xcode, and the tools listed by the upstream project. The app does not bundle those tools or install system dependencies. Choose **Settings → Install NXNative** to clone the engine. Switch 1 packages need a readable `prod.keys`; Switch 2 `.nup` containers do not.

The native interface does not yet include the earlier Python edition's controller calibration or build-history views. The packages, library, preferences and engine checkout use the native app's own data store; existing data in the earlier SQLite catalogue is not migrated automatically.

## Earlier Python interface

The Python + PySide6 front end remains available as an earlier edition. Its UI contains Games / Controllers / Import pages, SQLite persistence, controller calibration storage, and the workflows documented below.

> **Current delivery: source release 0.1.0.** The application shell, Games / Controllers / Import pages, SQLite persistence, package registration, engine clone/update workflow, JSON build monitor, build history, screenshots folder access, themes, and controller calibration storage are implemented in this source release. This is not yet a validated production `.app`: macOS hardware testing, package metadata verification, end-to-end builds, and the NX Native controller-remapping contract still need validation on the target Mac.

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
cd NXManager
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

NX Native's own per-game saves, settings, screenshots and logs remain in the locations documented by NX Native, not copied into NXManager.

## Controller calibration: important limitation

The Controllers page uses Apple's GameController framework (through PyObjC) to detect standard controller elements and guide a button / D-pad / stick calibration. Profiles can be stored globally or associated with a game and a detected device.

NX Native also documents `DM_HID_MAP`, `DM_HID_LOG` and per-game `env.txt` for raw HID controllers that macOS does not expose through GameController (for example, some 8BitDo modes). The UI can enable `DM_HID_LOG=1` and write the documented face-button mapping `DM_HID_MAP=A=...,B=...,X=...,Y=...` to `~/Library/Application Support/nxnative/<TITLE_ID>/env.txt`, preserving unrelated settings. The numeric codes must be read from the game's NX Native log and entered by the user. This is intentionally not applied to controllers already handled by Apple's GameController framework: NX Native's documentation says those use the native controller path, not this raw-HID remap.

The calibration wizard's GameController result is a record of standardized logical elements macOS reports, not raw USB HID usages. It is saved as an NXManager profile and is not automatically converted into `DM_HID_MAP`. The currently documented `DM_HID_MAP` example remaps only the four face buttons; the documentation does not define a stick-axis remap. This avoids silently applying a mapping to the wrong controller path or claiming unsupported stick remapping.

## Package identification

The native importer accepts `.XCI`, `.NSP`, `.NSZ`, `.XCZ` and `.NUP` case-insensitively. For Switch 2, select a folder containing exactly one `.nup` file; NXNative reads the title metadata from the container and builds it without `prod.keys`. NUP folders cannot be mixed with Switch 1 packages. For other package types NXManager reads Title ID and version from common filename markers such as `[0100...][v0]`; NXNative performs the authoritative package analysis during its build.

## Build flow

NXManager invokes the upstream `scripts/build_ipa_from_nsp.py` with `--platform mac-app`, `--progress json`, `--work-dir`, and `-o`. It passes `-k` for Switch 1 packages and omits it for NUP containers. It parses the documented newline-delimited JSON events, checks the process exit code, and verifies that the requested `.app` output exists. Cancelling sends a termination signal to the process.

The app does not fabricate percentages: when the engine reports no countable fraction, the progress bar remains indeterminate. Detailed tool logs are kept under NXManager Logs; the engine also keeps its own build logs.

## Tests

```bash
python -m pytest
python -m compileall -q nxmanager
```

The tests currently cover package filename parsing and supported extensions. The full macOS UI, controller framework, engine installation/update, and real game build need on-device integration tests.

## Upstream references

- https://github.com/seedds/nxnative
- https://github.com/seedds/nxnative/blob/main/docs/frontends.md
- https://github.com/seedds/nxnative/blob/main/scripts/build_ipa_from_nsp.py

NXManager is an independent front end and is not affiliated with Nintendo or the NX Native maintainers.
