# NXManager implementation status

Date: 18 November 2026

## Native SwiftUI app

The supported NXManager interface is the native macOS app in `NativeApp/`. It provides a game library, package and compiled-app import, NUP support, background builds with JSON progress, custom cover art, game-app-icon cover reuse, online banner lookup, controller calibration, HID settings, and per-game build status/logs. The app stores its library in `~/Library/Application Support/NXManager/library.json` and does not move original package files.

Build the macOS app from source with `./build_macos.sh`; the script writes `dist/NXManager.app`.

## NXNative setup

The first-launch wizard checks Xcode and Python, helps select `prod.keys`, and can clone NXNative and prepare an isolated Python environment with NXNative's Python modules. Switch 1 builds need a readable `prod.keys`; Switch 2 NUP builds do not.

A complete guided initializer for the NXNative system toolchain is planned. The current app does not install Xcode, Metal, Homebrew, Git, XcodeGen, zstd, glslang, or .NET automatically. Users still need to install system tools according to NXNative's current upstream requirements. These may change over time.

## Known limitations

1. Switch 1 Title IDs and versions are inferred from common filename markers; NXNative remains the authority for package metadata.
2. For NUP-only games, NXManager learns the Title ID from the generated app after a successful build. Save-folder shortcuts and Title-ID artwork lookup are unavailable before that build.
3. Automatic banner artwork lookup requires network access; users can choose cover art manually or reuse the latest built app's icon without rebuilding.
4. HID calibration records controller inputs. `DM_HID_MAP` supports the documented face-button mapping; NXNative does not document stick-axis remapping through this interface.
5. Cancelled builds send SIGTERM and are force-stopped with SIGKILL after five seconds. Descendant processes are not explicitly managed as a process group.
6. Developer ID signing, notarization, and final Finder verification remain release tasks.

## Verification

- `./tests/run_native_unit_tests.sh` covers Title ID validation, library status, HID configuration, and controller profile helpers.
- `swiftc -frontend -parse NativeApp/ContentView.swift NativeApp/AppModel.swift` checks Swift syntax without building the UI target.
- Full UI, physical controller, NXNative installation, and real game-build integration still require validation on the target Mac.

## Upstream references

- Build protocol: `https://github.com/seedds/nxnative/blob/main/docs/frontends.md` and `scripts/build_ipa_from_nsp.py`.
- macOS, Xcode, Python, and system-tool requirements: the upstream `README.md`.
