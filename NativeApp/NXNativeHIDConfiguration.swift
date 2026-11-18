import Foundation

enum NXNativeHIDConfiguration {
    static let buttons = ["A", "B", "X", "Y", "LS", "RS", "L", "R", "ZL", "ZR", "PLUS", "MINUS", "LEFT", "UP", "RIGHT", "DOWN"]

    static func envFile(titleID: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        guard titleID.count == 16,
              titleID.range(of: #"^[0-9A-Fa-f]{16}$"#, options: .regularExpression) != nil else {
            throw ConfigurationError.invalidTitleID
        }
        return homeDirectory.appendingPathComponent("Library/Application Support/nxnative/\(titleID.uppercased())/env.txt")
    }

    static func logFile(titleID: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        guard titleID.count == 16,
              titleID.range(of: #"^[0-9A-Fa-f]{16}$"#, options: .regularExpression) != nil else {
            throw ConfigurationError.invalidTitleID
        }
        return homeDirectory.appendingPathComponent("Library/Logs/nxnative/\(titleID.uppercased()).log")
    }

    static func read(_ url: URL) -> [String: String] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return contents.split(whereSeparator: \.isNewline).reduce(into: [:]) { values, rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { return }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            values[key] = value
        }
    }

    static func readLogTail(_ url: URL, maxBytes: Int = 262_144) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return String(decoding: data.suffix(max(0, maxBytes)), as: UTF8.self)
    }

    static func parseMap(_ value: String?) -> [String: String] {
        guard let value else { return [:] }
        var result: [String: String] = [:]
        for entry in value.split(separator: ",") {
            let parts = entry.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, buttons.contains(parts[0]), let code = Int(parts[1]), (1...32).contains(code) else { continue }
            result[parts[0]] = String(code)
        }
        return result
    }

    static func serializedMap(_ values: [String: String]) throws -> String? {
        var entries: [String] = []
        for button in buttons {
            let raw = (values[button] ?? "").trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }
            guard let code = Int(raw), (1...32).contains(code) else {
                throw ConfigurationError.invalidButtonUsage(button)
            }
            entries.append("\(button)=\(code)")
        }
        return entries.isEmpty ? nil : entries.joined(separator: ",")
    }

    static func update(_ url: URL, mapping: String?, logEnabled: Bool) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let oldLines = (try? String(contentsOf: url, encoding: .utf8))?.components(separatedBy: .newlines) ?? []
        let updates: [String: String?] = ["DM_HID_MAP": mapping, "DM_HID_LOG": logEnabled ? "1" : nil]
        var output: [String] = []
        var seen = Set<String>()
        for line in oldLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let key: String? = if !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") {
                String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            } else { nil }
            guard let key, let replacement = updates[key] else {
                if let key, updates[key] != nil { continue }
                output.append(line)
                continue
            }
            guard seen.insert(key).inserted else { continue }
            if let replacement { output.append("\(key)=\(replacement)") }
        }
        for key in ["DM_HID_MAP", "DM_HID_LOG"] where !seen.contains(key) {
            if let replacement = updates[key] ?? nil { output.append("\(key)=\(replacement)") }
        }
        let text = output.joined(separator: "\n").trimmingCharacters(in: .newlines)
        try (text.isEmpty ? "" : text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func recentButtonUsages(in log: String, controllerName: String? = nil) -> [Int] {
        var seen = Set<Int>()
        return log.components(separatedBy: .newlines).reversed().compactMap { line in
            guard line.localizedCaseInsensitiveContains("button usage "),
                  controllerName.map({ line.localizedCaseInsensitiveContains($0) }) ?? true,
                  let marker = line.range(of: "button usage ", options: .caseInsensitive),
                  let usage = Int(line[marker.upperBound...].prefix(while: \.isNumber)),
                  (1...32).contains(usage), seen.insert(usage).inserted else { return nil }
            return usage
        }
    }

    enum ConfigurationError: LocalizedError {
        case invalidTitleID
        case invalidButtonUsage(String)

        var errorDescription: String? {
            switch self {
            case .invalidTitleID: return "This game has no valid 16-digit title ID."
            case .invalidButtonUsage(let button): return "Enter an HID button usage from 1 to 32 for \(button), or leave it blank to keep the NXNative default."
            }
        }
    }
}
