import AppKit
import Foundation
import IOKit.hid

private enum HIDRunLoop {
    static let mode = CFStringCreateWithCString(nil, "kCFRunLoopDefaultMode", CFStringBuiltInEncodings.UTF8.rawValue)!
}

struct ControllerCalibrationStep: Identifiable, Equatable {
    enum Kind: Equatable { case button, stickAxis }
    let id: String
    let title: String
    let instruction: String
    let kind: Kind

    static let all: [ControllerCalibrationStep] = {
        let buttons: [(String, String)] = [
            ("A", "Press the right face button (A)."), ("B", "Press the bottom face button (B)."),
            ("X", "Press the top face button (X)."), ("Y", "Press the left face button (Y)."),
            ("L", "Press the left shoulder button (L)."), ("R", "Press the right shoulder button (R)."),
            ("ZL", "Press the left trigger fully."), ("ZR", "Press the right trigger fully."),
            ("LS", "Click the left stick."), ("RS", "Click the right stick."),
            ("PLUS", "Press the Plus / Start button."), ("MINUS", "Press the Minus / Select button."),
            ("UP", "Press D-pad Up."), ("DOWN", "Press D-pad Down."),
            ("LEFT", "Press D-pad Left."), ("RIGHT", "Press D-pad Right.")
        ]
        let buttonSteps = buttons.map { target, instruction in
            ControllerCalibrationStep(id: "button.\(target)", title: target, instruction: instruction, kind: .button)
        }
        let axes: [(String, String)] = [
            ("LS_UP", "Push the left stick fully up."), ("LS_DOWN", "Push the left stick fully down."),
            ("LS_LEFT", "Push the left stick fully left."), ("LS_RIGHT", "Push the left stick fully right."),
            ("RS_UP", "Push the right stick fully up."), ("RS_DOWN", "Push the right stick fully down."),
            ("RS_LEFT", "Push the right stick fully left."), ("RS_RIGHT", "Push the right stick fully right.")
        ]
        let axisSteps = axes.map { target, instruction in
            ControllerCalibrationStep(id: "axis.\(target)", title: target.replacingOccurrences(of: "_", with: " "), instruction: instruction, kind: .stickAxis)
        }
        return buttonSteps + axisSteps
    }()
}

struct CapturedHIDInput: Codable, Equatable {
    enum Kind: String, Codable { case button, hat, axis }
    var kind: Kind
    var page: Int
    var usage: Int
    var value: Double
    var logicalMin: Int
    var logicalMax: Int
}

struct ControllerMappingProfile: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var gameTitleID: String
    var controllerName: String
    var controllerID: String
    var createdAt: Date
    var buttonUsages: [String: String]
    var capturedInputs: [String: CapturedHIDInput]
    var compatibility: [String: Bool]
}

enum ControllerProfileStore {
    static func fileURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent("Library/Application Support/NXManager/Data/ControllerProfiles.json")
    }

    static func load(from url: URL) -> [ControllerMappingProfile] {
        guard let data = try? Data(contentsOf: url),
              let profiles = try? JSONDecoder().decode([ControllerMappingProfile].self, from: data) else { return [] }
        return profiles
    }

    static func save(_ profile: ControllerMappingProfile, to url: URL) throws -> [ControllerMappingProfile] {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var profiles = load(from: url)
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
        else { profiles.insert(profile, at: 0) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: url, options: .atomic)
        return profiles
    }

    static func delete(id: String, from url: URL) throws -> [ControllerMappingProfile] {
        let profiles = load(from: url).filter { $0.id != id }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: url, options: .atomic)
        return profiles
    }
}

final class RawHIDControllerCapture {
    enum CaptureError: LocalizedError {
        case managerUnavailable(Int32)

        var errorDescription: String? {
            switch self {
            case .managerUnavailable(let result):
                return "macOS could not open this controller for calibration (IOKit error \(result)). Check Input Monitoring permission and reconnect the controller."
            }
        }
    }

    private var manager: IOHIDManager?
    private var eventHandler: ((CapturedHIDInput) -> Void)?
    private var matchingContext: Unmanaged<RawHIDControllerCapture>?

    func start(vendorID: Int, productID: Int, locationID: Int?, onInput: @escaping (CapturedHIDInput) -> Void) throws {
        stop()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        var match: [String: Any] = [
            kIOHIDPrimaryUsagePageKey as String: 0x01,
            kIOHIDVendorIDKey as String: vendorID,
            kIOHIDProductIDKey as String: productID
        ]
        if let locationID { match[kIOHIDLocationIDKey as String] = locationID }
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        eventHandler = onInput
        let context = Unmanaged.passUnretained(self)
        matchingContext = context
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard result == kIOReturnSuccess, let context else { return }
            let capture = Unmanaged<RawHIDControllerCapture>.fromOpaque(context).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            let page = Int(IOHIDElementGetUsagePage(element))
            let usage = Int(IOHIDElementGetUsage(element))
            let rawValue = Double(IOHIDValueGetIntegerValue(value))
            let kind: CapturedHIDInput.Kind
            if page == 0x09 && (1...32).contains(usage) { kind = .button }
            else if page == 0x01 && usage == 0x39 { kind = .hat }
            // HID devices do not consistently label Generic Desktop axes as
            // Input_Axis. Several controllers expose X/Y/Z/Rx/Ry/Rz as
            // Input_Misc even though their usages and logical ranges are valid.
            // Classify the usages NXNative understands instead of relying on
            // the element's implementation-specific type.
            else if (page == 0x01 && (0x30...0x35).contains(usage))
                    || (page == 0x02 && [0xC4, 0xC5].contains(usage)) { kind = .axis }
            else { return }
            let input = CapturedHIDInput(kind: kind, page: page, usage: usage, value: rawValue,
                                         logicalMin: Int(IOHIDElementGetLogicalMin(element)),
                                         logicalMax: Int(IOHIDElementGetLogicalMax(element)))
            DispatchQueue.main.async { capture.eventHandler?(input) }
        }, context.toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), HIDRunLoop.mode)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), HIDRunLoop.mode)
            eventHandler = nil
            matchingContext = nil
            throw CaptureError.managerUnavailable(result)
        }
        self.manager = manager
    }

    func stop() {
        guard let manager else { eventHandler = nil; matchingContext = nil; return }
        IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), HIDRunLoop.mode)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        eventHandler = nil
        matchingContext = nil
    }

    deinit { stop() }
}
