import AppKit
import Foundation

@main
enum NativeUnitTests {
    static func main() {
        precondition(NXTitleID.normalize("0100f2c0115b6000") == "0100F2C0115B6000")
        precondition(NXTitleID.normalize("invalid") == nil)
        expect(.building, last: "building", compiled: false, base: true)
        expect(.failed, last: "failed", compiled: true, base: true)
        expect(.readyToPlay, last: nil, compiled: true, base: true)
        expect(.readyToBuild, last: nil, compiled: false, base: true)
        expect(.notBuilt, last: nil, compiled: false, base: false)
        precondition(GameLibraryStatus(lastBuildStatus: "building", hasCompiledApp: false, hasBasePackage: false).title == "BUILDING")
        precondition(GameLibraryStatus(lastBuildStatus: nil, hasCompiledApp: true, hasBasePackage: false).title == "READY TO PLAY")
        testCompiledAppSelection()
        testArtworkSizing()
        testControllerNavigationInput()
        testHIDConfiguration()
        testControllerProfiles()
        print("Native unit checks passed, including cover sizing, controller navigation, stale build selection, HID mapping persistence, and log parsing")
    }

    private static func expect(_ expected: GameLibraryStatus, last: String?, compiled: Bool, base: Bool) {
        let result = GameLibraryStatus(lastBuildStatus: last, hasCompiledApp: compiled, hasBasePackage: base)
        precondition(result == expected, "Expected \\(expected), got \\(result)")
    }

    private static func testArtworkSizing() {
        let canvas = CGSize(width: 300, height: 300)
        let extractedSquareIcon = ArtworkSizing.aspectFit(source: CGSize(width: 512, height: 512), inside: canvas)
        let customPortraitPoster = ArtworkSizing.aspectFit(source: CGSize(width: 1200, height: 1800), inside: canvas)
        let customLandscapePoster = ArtworkSizing.aspectFit(source: CGSize(width: 1800, height: 1200), inside: canvas)

        precondition(extractedSquareIcon == CGSize(width: 300, height: 300))
        precondition(customPortraitPoster == CGSize(width: 200, height: 300))
        precondition(customLandscapePoster == CGSize(width: 300, height: 200))
        for fitted in [extractedSquareIcon, customPortraitPoster, customLandscapePoster] {
            precondition(fitted.width <= canvas.width && fitted.height <= canvas.height,
                         "Artwork must stay within the shared cover canvas")
        }
        precondition(ArtworkSizing.aspectFit(source: .zero, inside: canvas) == .zero)

        var pixels = [UInt8](repeating: 0, count: 100 * 100 * 4)
        for y in 10..<90 {
            for x in 20..<80 {
                let offset = (y * 100 + x) * 4
                pixels[offset] = 255
                pixels[offset + 1] = 255
                pixels[offset + 2] = 255
                pixels[offset + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cgImage = CGImage(width: 100, height: 100, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: 100 * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
                              provider: provider, decode: nil, shouldInterpolate: false,
                              intent: .defaultIntent)!
        let paddedImage = NSImage(cgImage: cgImage, size: CGSize(width: 100, height: 100))
        let cropped = ArtworkSizing.trimTransparentMargins(in: paddedImage)
        precondition(cropped.size == CGSize(width: 60, height: 80),
                     "Transparent margins must be removed so the visible cover art can be enlarged")
    }

    private static func testCompiledAppSelection() {
        let stale = CompiledApp(path: "/missing/old-name.app")
        let current = CompiledApp(path: "/builds/current-name.app")
        let selected = CompiledAppSelection.firstExisting(in: [stale, current]) { $0 == current.path }
        precondition(selected == current, "Launching must skip stale build paths and select an existing app")
        precondition(CompiledAppSelection.firstExisting(in: [stale]) { _ in false } == nil,
                     "A game with no existing app must not be treated as playable")
    }

    private static func testControllerNavigationInput() {
        precondition(ControllerNavigationInput.direction(x: -0.8, y: 0) == -2)
        precondition(ControllerNavigationInput.direction(x: 0.8, y: 0) == 2)
        precondition(ControllerNavigationInput.direction(x: 0, y: 0.8) == -1)
        precondition(ControllerNavigationInput.direction(x: 0, y: -0.8) == 1)
        precondition(ControllerNavigationInput.direction(x: 0.3, y: -0.2) == 0)

        precondition(ControllerNavigationInput.direction(value: 255, logicalMin: 0, logicalMax: 255,
                                                          horizontal: true) == 2)
        precondition(ControllerNavigationInput.direction(value: -32768, logicalMin: -32768, logicalMax: 32767,
                                                          horizontal: false) == -1)
        precondition(ControllerNavigationInput.direction(value: 127.5, logicalMin: 0, logicalMax: 255,
                                                          horizontal: true) == 0)
        precondition(ControllerNavigationInput.direction(value: 1, logicalMin: 1, logicalMax: 1,
                                                          horizontal: true) == nil)
        precondition(ControllerNavigationInput.buttonAction(usage: 2) == .accept)
        precondition(ControllerNavigationInput.buttonAction(usage: 1) == .back)
        precondition(ControllerNavigationInput.buttonAction(usage: 3) == .accept)
        precondition(ControllerNavigationInput.buttonAction(usage: 7) == nil)
        precondition(ControllerNavigationInput.buttonAction(usage: 3, acceptUsage: 3, backUsage: 4) == .accept)

        let cards = [
            ControllerNavigationEntry(id: "first", order: 0, row: 0, column: 0),
            ControllerNavigationEntry(id: "second", order: 1, row: 0, column: 1),
            ControllerNavigationEntry(id: "third", order: 2, row: 1, column: 0)
        ]
        let right = ControllerNavigationInput.direction(x: 0.8, y: 0)
        let secondCard = ControllerNavigationGrid.destination(currentID: "missing", direction: right, entries: cards)
        precondition(secondCard == "second",
                     "Navigation must recover from focus IDs that have not been registered")
        precondition(ControllerNavigationGrid.destination(currentID: "second", direction: 1, entries: cards) == "third")
        precondition(ControllerNavigationGrid.focusedID(currentID: "missing", entries: cards) == "first")
        precondition(ControllerNavigationGrid.sequentialDestination(currentID: "missing", direction: 2, entries: cards) == "second")
        var activatedCard: String?
        let activated = ControllerNavigationGrid.activate(currentID: secondCard, entries: cards) { activatedCard = $0 }
        precondition(activated == "second" && activatedCard == "second",
                     "The accept action must launch the currently focused game card")
    }

    private static func testHIDConfiguration() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "0100f7e00c70e000"
        let env = try! NXNativeHIDConfiguration.envFile(titleID: id, homeDirectory: root)
        let log = try! NXNativeHIDConfiguration.logFile(titleID: id, homeDirectory: root)
        precondition(env.path.hasSuffix("Library/Application Support/nxnative/0100F7E00C70E000/env.txt"))
        precondition(log.path.hasSuffix("Library/Logs/nxnative/0100F7E00C70E000.log"))
        precondition(NXNativeHIDConfiguration.buttons.count == 16)
        precondition(NXNativeHIDConfiguration.parseMap("A=2,Y=5,NOPE=1,A=34") == ["A": "2", "Y": "5"])
        precondition(try! NXNativeHIDConfiguration.serializedMap(["B": "1", "A": "2"]) == "A=2,B=1")

        do {
            _ = try NXNativeHIDConfiguration.envFile(titleID: "bad", homeDirectory: root)
            preconditionFailure("invalid title ID must be rejected")
        } catch NXNativeHIDConfiguration.ConfigurationError.invalidTitleID { }
        catch { preconditionFailure("unexpected title ID validation error: \(error)") }
        do {
            _ = try NXNativeHIDConfiguration.serializedMap(["A": "33"])
            preconditionFailure("usage outside the documented 1...32 range must be rejected")
        } catch NXNativeHIDConfiguration.ConfigurationError.invalidButtonUsage("A") { }
        catch { preconditionFailure("unexpected HID usage validation error: \(error)") }

        try! FileManager.default.createDirectory(at: env.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! "# preserve this comment\nDM_FPS_TARGET=30\nDM_HID_MAP=A=1\nDM_HID_MAP=B=2\nDM_HID_LOG=0\n".write(to: env, atomically: true, encoding: .utf8)
        try! NXNativeHIDConfiguration.update(env, mapping: "A=3,Y=7", logEnabled: true)
        let savedText = try! String(contentsOf: env, encoding: .utf8)
        let saved = NXNativeHIDConfiguration.read(env)
        precondition(savedText.contains("# preserve this comment"))
        precondition(saved["DM_FPS_TARGET"] == "30")
        precondition(saved["DM_HID_MAP"] == "A=3,Y=7")
        precondition(saved["DM_HID_LOG"] == "1")
        precondition(savedText.components(separatedBy: "DM_HID_MAP=").count - 1 == 1)

        try! NXNativeHIDConfiguration.update(env, mapping: nil, logEnabled: false)
        let cleared = NXNativeHIDConfiguration.read(env)
        precondition(cleared["DM_HID_MAP"] == nil && cleared["DM_HID_LOG"] == nil)
        precondition(cleared["DM_FPS_TARGET"] == "30")

        let parsed = NXNativeHIDConfiguration.recentButtonUsages(in: "[hid] NSW Wired controller: button usage 3\n[hid] Other Pad: button usage 7\n[hid] NSW Wired controller: button usage 3\n[hid] NSW Wired controller: button usage 33", controllerName: "NSW Wired controller")
        precondition(parsed == [3])
        let sampleLog = root.appendingPathComponent("sample.log")
        try! (String(repeating: "old log line\n", count: 100) + "[hid] NSW Wired controller: button usage 9\n")
            .write(to: sampleLog, atomically: true, encoding: .utf8)
        let tail = NXNativeHIDConfiguration.readLogTail(sampleLog, maxBytes: 128)!
        precondition(NXNativeHIDConfiguration.recentButtonUsages(in: tail, controllerName: "NSW Wired controller") == [9])
    }

    private static func testControllerProfiles() {
        precondition(ControllerCalibrationStep.all.count == 24)
        precondition(ControllerCalibrationStep.all.filter { $0.kind == .button }.count == 16)
        precondition(ControllerCalibrationStep.all.filter { $0.kind == .stickAxis }.count == 8)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("ControllerProfiles.json")
        let profile = ControllerMappingProfile(id: "test", name: "Test layout", gameTitleID: "0100ABCD00000000",
            controllerName: "Test pad", controllerID: "hid-1", createdAt: Date(), buttonUsages: ["A": "2"],
            capturedInputs: ["button.A": CapturedHIDInput(kind: .button, page: 9, usage: 2, value: 1, logicalMin: 0, logicalMax: 1)],
            compatibility: ["button.A": true])
        let saved = try! ControllerProfileStore.save(profile, to: file)
        precondition(saved == [profile])
        precondition(ControllerProfileStore.load(from: file) == [profile])
    }
}
