import Foundation

enum NXTitleID {
    static func normalize(_ value: String?) -> String? {
        guard let value, value.range(of: #"^[0-9A-Fa-f]{16}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return value.uppercased()
    }
}

struct GamePackage: Identifiable, Codable, Hashable {
    var id = UUID()
    var path: String
    var role: String
    var version: String?

    var fileURL: URL { URL(fileURLWithPath: path) }
}

struct CompiledApp: Identifiable, Codable, Hashable {
    var id = UUID()
    var path: String
    var version: String?

    var fileURL: URL { URL(fileURLWithPath: path) }
    var name: String { fileURL.deletingPathExtension().lastPathComponent }
}

struct Game: Identifiable, Codable, Hashable {
    var id: String
    var titleID: String?
    var name: String
    var packages: [GamePackage]
    var coverPath: String?
    var buildIconPath: String?
    var bannerPath: String?
    var builtAppPath: String?
    var lastBuildStatus: String?
    var lastBuildMessage: String?
    var lastBuildLog: [String]?
    var compiledApps: [CompiledApp]

    init(id: String, titleID: String?, name: String, packages: [GamePackage], coverPath: String? = nil, buildIconPath: String? = nil, bannerPath: String? = nil,
         builtAppPath: String? = nil, lastBuildStatus: String? = nil, lastBuildMessage: String? = nil,
         lastBuildLog: [String]? = nil, compiledApps: [CompiledApp] = []) {
        self.id = id
        self.titleID = titleID
        self.name = name
        self.packages = packages
        self.coverPath = coverPath
        self.buildIconPath = buildIconPath
        self.bannerPath = bannerPath
        self.builtAppPath = builtAppPath
        self.lastBuildStatus = lastBuildStatus
        self.lastBuildMessage = lastBuildMessage
        self.lastBuildLog = lastBuildLog
        self.compiledApps = compiledApps
        if compiledApps.isEmpty, let builtAppPath {
            self.compiledApps = [CompiledApp(path: builtAppPath)]
        }
    }

    var hasBasePackage: Bool { packages.contains { $0.role == "base" } }
    /// NXNative reads Switch 2 games from a single NUP container and does not need prod.keys.
    var usesNUPContainer: Bool { packages.contains { $0.fileURL.pathExtension.lowercased() == "nup" } }
    var allCompiledApps: [CompiledApp] {
        if !compiledApps.isEmpty { return compiledApps }
        if let builtAppPath { return [CompiledApp(path: builtAppPath)] }
        return []
    }

    private enum CodingKeys: String, CodingKey {
        case id, titleID, name, packages, coverPath, buildIconPath, bannerPath, builtAppPath, lastBuildStatus, lastBuildMessage, lastBuildLog, compiledApps
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        titleID = try values.decodeIfPresent(String.self, forKey: .titleID)
        name = try values.decode(String.self, forKey: .name)
        packages = try values.decodeIfPresent([GamePackage].self, forKey: .packages) ?? []
        coverPath = try values.decodeIfPresent(String.self, forKey: .coverPath)
        buildIconPath = try values.decodeIfPresent(String.self, forKey: .buildIconPath)
        bannerPath = try values.decodeIfPresent(String.self, forKey: .bannerPath)
        builtAppPath = try values.decodeIfPresent(String.self, forKey: .builtAppPath)
        lastBuildStatus = try values.decodeIfPresent(String.self, forKey: .lastBuildStatus)
        lastBuildMessage = try values.decodeIfPresent(String.self, forKey: .lastBuildMessage)
        lastBuildLog = try values.decodeIfPresent([String].self, forKey: .lastBuildLog)
        compiledApps = try values.decodeIfPresent([CompiledApp].self, forKey: .compiledApps) ?? []
        if compiledApps.isEmpty, let builtAppPath {
            compiledApps = [CompiledApp(path: builtAppPath)]
        }
    }
}

struct LibraryData: Codable {
    var games: [Game] = []
}

enum AppSection: Hashable {
    case library
    case importing
    case controller
    case settings
}
