import AppKit
import Combine
import Darwin
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var games: [Game] = []
    @Published var selectedSection: AppSection? = .library
    @Published var selectedGameID: String?
    @Published var keysPath: String { didSet { defaults.set(keysPath, forKey: "keysPath") } }
    @Published var enginePath: String { didSet { defaults.set(enginePath, forKey: "enginePath") } }
    @Published var outputPath: String { didSet { defaults.set(outputPath, forKey: "outputPath") } }
    @Published var engineMessage = "Engine not configured"
    @Published var engineBusy = false
    @Published var buildGameID: String?
    @Published var buildHasStarted = false
    @Published var buildMessage = ""
    @Published var buildLog: [String] = []
    @Published var buildFraction: Double?
    @Published var alertMessage: String?
    @Published var appearance: String { didSet { defaults.set(appearance, forKey: "appearance") } }
    @Published var setupBusy = false
    @Published var setupMessage = "Ready to check requirements"
    @Published var setupStartedAt: Date?
    @Published var xcodeMessage = "Not checked"
    @Published var pythonMessage = "Not checked"
    @Published var pythonReady = false
    @Published var artworkLoadingGameIDs: Set<String> = []

    private let defaults = UserDefaults.standard
    private let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/NXManager", isDirectory: true)
    private var process: Process?
    private var outputBuffer = ""
    private var cancelRequested = false

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = home.appendingPathComponent("Library/Application Support/NXManager", isDirectory: true)
        self.keysPath = defaults.string(forKey: "keysPath") ?? home.appendingPathComponent(".switch/prod.keys").path
        self.enginePath = defaults.string(forKey: "enginePath") ?? base.appendingPathComponent("Engine/nxnative").path
        self.outputPath = defaults.string(forKey: "outputPath") ?? home.appendingPathComponent("Games/NXManager Builds").path
        self.appearance = defaults.string(forKey: "appearance") ?? "system"
        loadLibrary()
        refreshEngineStatus()
    }

    var selectedGame: Game? { games.first { $0.id == selectedGameID } }
    var validKeys: Bool { FileManager.default.isReadableFile(atPath: (keysPath as NSString).expandingTildeInPath) }
    var engineReady: Bool { FileManager.default.fileExists(atPath: URL(fileURLWithPath: (enginePath as NSString).expandingTildeInPath).appendingPathComponent("scripts/build_ipa_from_nsp.py").path) }

    func ensureBannerArtwork(for gameID: String) {
        guard let game = games.first(where: { $0.id == gameID }), let titleID = game.titleID,
              game.bannerPath.map({ FileManager.default.fileExists(atPath: $0) }) != true,
              !artworkLoadingGameIDs.contains(gameID) else { return }
        artworkLoadingGameIDs.insert(gameID)
        Task {
            defer { artworkLoadingGameIDs.remove(gameID) }
            do {
                let artworkDirectory = support.appendingPathComponent("Data/Artwork", isDirectory: true)
                try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
                let bannerFile = artworkDirectory.appendingPathComponent("\(titleID.uppercased())-banner.jpg")
                if FileManager.default.fileExists(atPath: bannerFile.path) {
                    updateBannerPath(gameID: gameID, path: bannerFile.path)
                    return
                }
                let indexURL = artworkDirectory.appendingPathComponent("banner-index.json")
                var index = (try? Data(contentsOf: indexURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
                let key = titleID.uppercased()
                if index[key] == nil {
                    setupMessage = "Looking up game artwork…"
                    let databaseURL = URL(string: "https://raw.githubusercontent.com/blawar/titledb/master/US.en.json")!
                    let (data, _) = try await URLSession.shared.data(from: databaseURL)
                    index.merge(Self.bannerIndex(from: data)) { current, _ in current }
                    if index[key] == nil { index[key] = "" }
                    try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
                }
                guard let address = index[key], !address.isEmpty, let imageURL = URL(string: address) else { return }
                let (data, response) = try await URLSession.shared.data(from: imageURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let image = NSImage(data: data), image.size.width > image.size.height else { return }
                try data.write(to: bannerFile, options: .atomic)
                updateBannerPath(gameID: gameID, path: bannerFile.path)
            } catch {
                // Missing artwork is non-fatal; the library keeps its existing cover art.
            }
        }
    }

    private func updateBannerPath(gameID: String, path: String) {
        guard let index = games.firstIndex(where: { $0.id == gameID }) else { return }
        games[index].bannerPath = path
        saveLibrary()
    }

    private static func bannerIndex(from data: Data) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        var result: [String: String] = [:]
        func visit(_ value: Any) {
            if let array = value as? [Any] { array.forEach(visit); return }
            guard let object = value as? [String: Any] else { return }
            if let record = object["bannerUrl"] as? String {
                for key in ["id", "titleID", "titleId"] {
                    if let id = object[key] as? String { result[id.uppercased()] = record }
                }
            }
            for (key, child) in object {
                if key.range(of: #"^[0-9A-Fa-f]{16}$"#, options: .regularExpression) != nil,
                   let record = child as? [String: Any], let banner = record["bannerUrl"] as? String {
                    result[key.uppercased()] = banner
                } else { visit(child) }
            }
        }
        visit(root)
        return result
    }

    func checkSetupRequirements() {
        let result = runCommand("/usr/bin/xcode-select", arguments: ["-p"])
        if result.status == 0, FileManager.default.fileExists(atPath: result.output.trimmingCharacters(in: .whitespacesAndNewlines)) {
            xcodeMessage = "Xcode command line tools detected"
        } else {
            xcodeMessage = "Xcode is required"
        }
        let paths = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/python3" }
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            let result = runCommand(path, arguments: ["--version"])
            if result.status == 0, let match = result.output.range(of: #"Python (\d+)\.(\d+)"#, options: .regularExpression) {
                let version = String(result.output[match])
                let parts = version.dropFirst("Python ".count).split(separator: ".").compactMap { Int($0) }
                if parts.count == 2, (parts[0] > 3 || (parts[0] == 3 && parts[1] >= 12)) {
                    pythonMessage = "\(version) detected"
                    pythonReady = true
                    return
                }
            }
        }
        pythonMessage = "Python 3.12 or later is required"
        pythonReady = false
    }

    func prepareSetupPython() {
        guard !setupBusy else { return }
        checkSetupRequirements()
        guard pythonReady else {
            setupMessage = "Install Python 3.12 or later, then check again."
            return
        }
        let paths = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/python3" }
        guard let python = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) && runCommand($0, arguments: ["--version"]).status == 0 }) else { return }
        setupBusy = true
        setupStartedAt = Date()
        setupMessage = "Preparing isolated Python environment…"
        Task {
            do {
                _ = try await prepareBuildPython(basePython: python)
                setupMessage = "Python dependencies are ready"
            } catch {
                setupMessage = "Setup failed: \(error.localizedDescription)"
            }
            setupBusy = false
            setupStartedAt = nil
        }
    }

    private var libraryURL: URL { support.appendingPathComponent("library.json") }

    private func loadLibrary() {
        do {
            let data = try Data(contentsOf: libraryURL)
            games = try JSONDecoder().decode(LibraryData.self, from: data).games
        } catch {
            games = []
        }
    }

    @discardableResult
    private func saveLibrary() -> Bool {
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let data = try JSONEncoder.pretty.encode(LibraryData(games: games))
            try data.write(to: libraryURL, options: .atomic)
            return true
        } catch {
            alertMessage = "The library could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func importPackages(_ urls: [URL], roles: [URL: String], gameName: String) -> Bool {
        do {
            for url in urls {
                guard ["xci", "nsp", "nsz", "xcz", "nup"].contains(url.pathExtension.lowercased()),
                      FileManager.default.isReadableFile(atPath: url.path) else {
                    throw NSError(domain: "NXManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "This package format is not supported."])
                }
                let info = packageInfo(url)
                let role = url.pathExtension.lowercased() == "nup" ? "base" : (roles[url] ?? info.role)
                let titleID = role == "update" ? baseTitleID(info.titleID) : info.titleID
                let gameID = titleID?.lowercased() ?? stablePackageID(url)
                let displayName = gameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? info.name : gameName
                let gameFolder = support.appendingPathComponent("Data/PackageLinks/\(gameID)", isDirectory: true)
                try FileManager.default.createDirectory(at: gameFolder, withIntermediateDirectories: true)
                let link = gameFolder.appendingPathComponent(url.lastPathComponent)
                if FileManager.default.fileExists(atPath: link.path) { try FileManager.default.removeItem(at: link) }
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)

                if let index = games.firstIndex(where: { $0.id == gameID }) {
                    if !games[index].packages.contains(where: { $0.path == url.path }) {
                        games[index].packages.append(GamePackage(path: url.path, role: role, version: info.version))
                    }
                } else {
                    games.append(Game(id: gameID, titleID: titleID, name: displayName, packages: [GamePackage(path: url.path, role: role, version: info.version)]))
                }
            }
            games.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            saveLibrary()
            selectedSection = .library
            if let first = urls.first, let title = packageInfo(first).titleID {
                let baseID = roles[first] == "update" ? baseTitleID(title) : title
                selectedGameID = games.first(where: { $0.titleID == baseID })?.id
            }
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func importGameFolder(_ folder: URL) -> Bool {
        let supported = Set(["xci", "nsp", "nsz", "xcz", "nup"])
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            alertMessage = "Choose a folder containing the game files."
            return false
        }
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            alertMessage = "The selected game folder could not be read."
            return false
        }
        let files = enumerator.compactMap { $0 as? URL }
            .filter { supported.contains($0.pathExtension.lowercased()) && FileManager.default.isReadableFile(atPath: $0.path) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !files.isEmpty else {
            alertMessage = "No supported game packages were found. NXNative accepts XCI, NSP, NSZ, XCZ, and NUP files."
            return false
        }
        let nupFiles = files.filter { $0.pathExtension.lowercased() == "nup" }
        if !nupFiles.isEmpty {
            guard nupFiles.count == 1, files.count == 1 else {
                alertMessage = "A Switch 2 NUP folder must contain exactly one .nup file and no NSP/XCI packages."
                return false
            }
            let nup = nupFiles[0]
            let gameID = stablePackageID(nup)
            let gameName = nup.deletingPathExtension().lastPathComponent
            let gameFolder = support.appendingPathComponent("Data/PackageLinks/\(gameID)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: gameFolder, withIntermediateDirectories: true)
                let link = gameFolder.appendingPathComponent(nup.lastPathComponent)
                if FileManager.default.fileExists(atPath: link.path) { try FileManager.default.removeItem(at: link) }
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: nup)
                let package = GamePackage(path: nup.path, role: "base", version: nil)
                if let index = games.firstIndex(where: { $0.id == gameID }) {
                    if !games[index].packages.contains(where: { $0.path == nup.path }) { games[index].packages.append(package) }
                } else {
                    games.append(Game(id: gameID, titleID: nil, name: gameName, packages: [package]))
                }
                games.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                saveLibrary()
                selectedGameID = gameID
                selectedSection = .library
                return true
            } catch {
                alertMessage = "The NUP file could not be added: \(error.localizedDescription)"
                return false
            }
        }
        let infos = files.map(packageInfo)
        let baseIndex = infos.firstIndex(where: { $0.role == "base" })
            ?? infos.firstIndex(where: { $0.role != "update" && !$0.name.localizedCaseInsensitiveContains("dlc") })
        guard let baseIndex, let baseTitleID = infos[baseIndex].titleID else {
            alertMessage = "Could not identify the base game. Make sure its package filename includes its 16-character title ID (and [v0] when available)."
            return false
        }
        let gameID = baseTitleID.lowercased()
        let gameName = folder.lastPathComponent
        let gameFolder = support.appendingPathComponent("Data/PackageLinks/\(gameID)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: gameFolder, withIntermediateDirectories: true)
            var packages: [GamePackage] = []
            for (index, file) in files.enumerated() {
                let info = infos[index]
                let role: String
                if index == baseIndex || info.role == "base" { role = "base" }
                else if info.role == "update" { role = "update" }
                else { role = "dlc" }
                let link = gameFolder.appendingPathComponent(file.lastPathComponent)
                if FileManager.default.fileExists(atPath: link.path) { try FileManager.default.removeItem(at: link) }
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
                packages.append(GamePackage(path: file.path, role: role, version: info.version))
            }
            if let existing = games.firstIndex(where: { $0.id == gameID }) {
                for package in packages where !games[existing].packages.contains(where: { $0.path == package.path }) {
                    games[existing].packages.append(package)
                }
            } else {
                games.append(Game(id: gameID, titleID: baseTitleID, name: gameName, packages: packages))
            }
            games.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            saveLibrary()
            selectedGameID = gameID
            selectedSection = .library
            return true
        } catch {
            alertMessage = "The packages could not be added: \(error.localizedDescription)"
            return false
        }
    }

    func importCompiledApp(_ appURL: URL) {
        guard appURL.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: appURL) else {
            alertMessage = "Choose a valid macOS app bundle."
            return
        }
        guard let titleID = NXTitleID.normalize(bundle.object(forInfoDictionaryKey: "DMTitleID") as? String) else {
            alertMessage = "This app is not recognized as an NXNative Switch game. Its Info.plist must contain a valid 16-character DMTitleID."
            return
        }
        guard let executable = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
              FileManager.default.isExecutableFile(atPath: appURL.appendingPathComponent("Contents/MacOS/\(executable)").path) else {
            alertMessage = "This NXNative game app is incomplete: its main executable could not be found."
            return
        }
        let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let compiled = CompiledApp(path: appURL.path, version: version)
        let gameID = titleID.lowercased()
        let match = games.firstIndex(where: { $0.id == gameID || ($0.titleID != nil && $0.titleID == titleID) })

        if let index = match {
            if games[index].allCompiledApps.contains(where: { $0.path == appURL.path }) {
                alertMessage = "This compiled game app is already in your library."
            } else {
                games[index].compiledApps.append(compiled)
            }
            if games[index].coverPath == nil {
                games[index].coverPath = saveAppIcon(at: appURL, identifier: games[index].id)?.path
            }
        } else {
            let cover = saveAppIcon(at: appURL, identifier: gameID)
            games.append(Game(id: gameID, titleID: titleID, name: displayName, packages: [],
                              coverPath: cover?.path, builtAppPath: appURL.path,
                              lastBuildStatus: "success", compiledApps: [compiled]))
        }
        games.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        saveLibrary()
        selectedGameID = games.first { $0.id == gameID || $0.titleID?.uppercased() == titleID }?.id
        selectedSection = .library
    }

    func openSaveFolder(for game: Game) {
        guard let titleID = game.titleID,
              titleID.range(of: "^[0-9A-Fa-f]{16}$", options: .regularExpression) != nil else {
            alertMessage = "This game has no valid Title ID, so NXNative's save folder cannot be located."
            return
        }
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/nxnative/\(titleID.uppercased())/save", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        } catch {
            alertMessage = "The save folder could not be opened: \(error.localizedDescription)"
        }
    }

    func setCover(for gameID: String, from sourceURL: URL) {
        do {
            let folder = support.appendingPathComponent("Data/Covers", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent("\(gameID)-poster.\(sourceURL.pathExtension.lowercased())")
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            if let index = games.firstIndex(where: { $0.id == gameID }) {
                games[index].coverPath = destination.path
                saveLibrary()
            }
        } catch {
            alertMessage = "The cover image could not be saved: \(error.localizedDescription)"
        }
    }

    func setBuildIcon(for gameID: String, from sourceURL: URL) {
        guard ["png", "jpg", "jpeg"].contains(sourceURL.pathExtension.lowercased()),
              let image = NSImage(contentsOf: sourceURL), image.isValid else {
            alertMessage = "Choose a valid PNG or JPEG image for the game app icon."
            return
        }
        do {
            let folder = support.appendingPathComponent("Data/Covers", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent("\(gameID)-custom-build-icon.\(sourceURL.pathExtension.lowercased())")
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            guard let index = games.firstIndex(where: { $0.id == gameID }) else { return }
            games[index].buildIconPath = destination.path
            saveLibrary()
        } catch {
            alertMessage = "The app icon could not be saved: \(error.localizedDescription)"
        }
    }

    func renameGame(_ gameID: String, to name: String) {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty, let index = games.firstIndex(where: { $0.id == gameID }) else { return }
        games[index].name = cleanedName
        games.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        saveLibrary()
    }

    func removeGame(_ game: Game) {
        games.removeAll { $0.id == game.id }
        if selectedGameID == game.id { selectedGameID = nil }
        let folder = support.appendingPathComponent("Data/PackageLinks/\(game.id)")
        try? FileManager.default.removeItem(at: folder)
        saveLibrary()
    }

    func fullDeletionSummary(for game: Game) -> String {
        "This permanently deletes this game’s save and settings, imported package files, compiled Mac apps, and its NXManager build, package-link, cover, and artwork data. Files shared with another game in your library are kept. Any locations NXManager cannot access will be reported after deletion."
    }

    func deleteGameCompletely(_ game: Game) {
        guard buildGameID != game.id else {
            alertMessage = "Wait for this game’s build to finish before deleting it."
            return
        }
        guard games.contains(where: { $0.id == game.id }) else { return }

        let otherGames = games.filter { $0.id != game.id }
        let sharedPackagePaths = Set(otherGames.flatMap(\.packages).map { Self.normalizedPath($0.path) })
        let sharedAppPaths = Set(otherGames.flatMap(\.allCompiledApps).map { Self.normalizedPath($0.path) })
        let sharedArtworkPaths = Set(otherGames.flatMap { [$0.coverPath, $0.bannerPath].compactMap { $0 } }
            .map { Self.normalizedPath($0) })
        var targets: [String: URL] = [:]
        var sharedResourceCount = 0

        func add(_ url: URL) {
            targets[Self.normalizedPath(url.path)] = url
        }

        func addArtwork(_ url: URL) {
            if sharedArtworkPaths.contains(Self.normalizedPath(url.path)) { sharedResourceCount += 1 }
            else { add(url) }
        }

        for package in game.packages {
            let key = Self.normalizedPath(package.path)
            if sharedPackagePaths.contains(key) { sharedResourceCount += 1 }
            else { add(URL(fileURLWithPath: package.path)) }
        }
        for app in game.allCompiledApps {
            let key = Self.normalizedPath(app.path)
            if sharedAppPaths.contains(key) { sharedResourceCount += 1 }
            else { add(app.fileURL) }
        }

        if let links = managedGameFolder("PackageLinks", gameID: game.id) { add(links) }
        if let builds = managedGameFolder("Builds", gameID: game.id) { add(builds) }

        let coverDirectory = support.appendingPathComponent("Data/Covers", isDirectory: true)
        if let coverPath = game.coverPath, Self.isDirectChild(coverPath, of: coverDirectory) {
            addArtwork(URL(fileURLWithPath: coverPath))
        }
        let artworkDirectory = support.appendingPathComponent("Data/Artwork", isDirectory: true)
        if let bannerPath = game.bannerPath, Self.isDirectChild(bannerPath, of: artworkDirectory) {
            addArtwork(URL(fileURLWithPath: bannerPath))
        }
        if Self.isSafePathComponent(game.id),
           let files = try? FileManager.default.contentsOfDirectory(at: coverDirectory, includingPropertiesForKeys: nil) {
            for file in files where ["-poster.", "-icon.", "-build-icon."].contains(where: { file.lastPathComponent.hasPrefix(game.id + $0) }) {
                addArtwork(file)
            }
        }

        if let titleID = game.titleID?.uppercased(), Self.isValidTitleID(titleID),
           !otherGames.contains(where: { $0.titleID?.uppercased() == titleID }) {
            let home = FileManager.default.homeDirectoryForCurrentUser
            add(home.appendingPathComponent("Library/Application Support/nxnative/\(titleID)", isDirectory: true))
            add(home.appendingPathComponent("Library/Logs/nxnative/\(titleID).log"))
            add(artworkDirectory.appendingPathComponent("\(titleID)-banner.jpg"))
        }

        let manager = FileManager.default
        var removedCount = 0
        var failures: [String] = []
        for url in targets.values {
            guard manager.fileExists(atPath: url.path) else { continue }
            do {
                try manager.removeItem(at: url)
                removedCount += 1
            } catch {
                failures.append("\(url.path): \(error.localizedDescription)")
            }
        }

        games.removeAll { $0.id == game.id }
        if selectedGameID == game.id { selectedGameID = nil }
        let librarySaved = saveLibrary()

        var report = librarySaved
            ? "\(game.name) was removed from the library. \(removedCount) file or folder location(s) deleted."
            : "Game data cleanup ran, but NXManager could not save the updated library. The game may still appear after a restart."
        if sharedResourceCount > 0 {
            report += " \(sharedResourceCount) shared package or app reference(s) were kept."
        }
        if !failures.isEmpty {
            report += " Some locations could not be deleted:\n" + failures.joined(separator: "\n")
        }
        alertMessage = report
    }

    private func managedGameFolder(_ category: String, gameID: String) -> URL? {
        guard Self.isSafePathComponent(gameID), ["PackageLinks", "Builds"].contains(category) else { return nil }
        return support.appendingPathComponent("Data/\(category)/\(gameID)", isDirectory: true)
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func isDirectChild(_ path: String?, of directory: URL) -> Bool {
        guard let path else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent().path
            == directory.standardizedFileURL.path
    }

    private static func isSafePathComponent(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }

    private static func isValidTitleID(_ value: String) -> Bool {
        value.range(of: #"^[0-9A-F]{16}$"#, options: .regularExpression) != nil
    }

    func refreshEngineStatus() {
        let script = URL(fileURLWithPath: enginePath).appendingPathComponent("scripts/build_ipa_from_nsp.py")
        engineMessage = FileManager.default.fileExists(atPath: script.path) ? "NXNative engine detected" : "NXNative engine not found"
    }

    func installOrUpdateEngine() {
        guard !engineBusy else { return }
        engineBusy = true
        engineMessage = "Preparing NXNative…"
        let directory = URL(fileURLWithPath: (enginePath as NSString).expandingTildeInPath)
        Task {
            do {
                try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                    _ = try await Self.run("/usr/bin/git", ["-C", directory.path, "pull", "--ff-only"])
                } else {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    _ = try await Self.run("/usr/bin/git", ["clone", "--depth", "1", "https://github.com/seedds/nxnative.git", directory.path])
                }
                engineMessage = "NXNative engine detected"
            } catch {
                engineMessage = "Installation stopped"
                alertMessage = error.localizedDescription
            }
            engineBusy = false
            refreshEngineStatus()
        }
    }

    func build(_ game: Game) {
        guard buildGameID == nil else { return }
        guard game.hasBasePackage else { alertMessage = "Add the base game package before starting a build."; return }
        guard game.usesNUPContainer || validKeys else { alertMessage = "Choose a readable prod.keys file in Settings."; selectedSection = .settings; return }
        let script = URL(fileURLWithPath: (enginePath as NSString).expandingTildeInPath).appendingPathComponent("scripts/build_ipa_from_nsp.py")
        guard FileManager.default.fileExists(atPath: script.path) else { alertMessage = "Install NXNative in Settings before building."; selectedSection = .settings; return }

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        guard let python = (["/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            + (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/python3" })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            markBuildUnavailable(game, reason: "Python 3.12 or later was not found. Install Python 3.12+ and try again.")
            return
        }
        let versionResult = runCommand(python, arguments: ["--version"])
        let versionRegex = try? NSRegularExpression(pattern: "Python (\\d+)\\.(\\d+)")
        let versionRange = NSRange(versionResult.output.startIndex..., in: versionResult.output)
        let versionMatch = versionRegex?.firstMatch(in: versionResult.output, range: versionRange)
        let versionNumbers = versionMatch.flatMap { match -> (Int, Int)? in
            guard let majorRange = Range(match.range(at: 1), in: versionResult.output),
                  let minorRange = Range(match.range(at: 2), in: versionResult.output),
                  let major = Int(versionResult.output[majorRange]),
                  let minor = Int(versionResult.output[minorRange]) else { return nil }
            return (major, minor)
        }
        guard versionResult.status == 0, let versionNumbers,
              versionNumbers.0 > 3 || (versionNumbers.0 == 3 && versionNumbers.1 >= 12) else {
            let detected = versionResult.output.isEmpty ? "No usable Python 3 installation was found." : "Detected: \(versionResult.output.trimmingCharacters(in: .whitespacesAndNewlines))."
            markBuildUnavailable(game, reason: "NXNative requires Python 3.12 or later. \(detected)")
            return
        }

        buildGameID = game.id
        buildHasStarted = false
        buildMessage = "Checking NXNative Python dependencies…"
        buildLog = [buildMessage]
        buildFraction = nil
        cancelRequested = false
        if let index = games.firstIndex(where: { $0.id == game.id }) {
            games[index].lastBuildStatus = nil
            games[index].lastBuildMessage = nil
            games[index].lastBuildLog = nil
            saveLibrary()
        }

        Task {
            do {
                let managedPython = try await prepareBuildPython(basePython: python)
                guard buildGameID == game.id else { return }
                if cancelRequested {
                    let message = "Build cancelled before NXNative started."
                    buildGameID = nil
                    buildHasStarted = false
                    buildMessage = message
                    buildLog.append(message)
                    if let index = games.firstIndex(where: { $0.id == game.id }) {
                        games[index].lastBuildStatus = "cancelled"
                        games[index].lastBuildMessage = message
                        games[index].lastBuildLog = buildLog
                        saveLibrary()
                    }
                    return
                }
                startBuild(game, python: managedPython)
            } catch {
                buildGameID = nil
                buildHasStarted = false
                markBuildUnavailable(game, reason: "Could not prepare NXNative's Python dependencies: \(error.localizedDescription)")
            }
        }
    }

    private func prepareBuildPython(basePython: String) async throws -> String {
        let environment = support.appendingPathComponent("Engine/PythonEnvironment", isDirectory: true)
        let managedPython = environment.appendingPathComponent("bin/python3").path
        try FileManager.default.createDirectory(at: environment.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.isExecutableFile(atPath: managedPython) {
            buildMessage = "Creating an isolated Python environment…"
            _ = try await Self.run(basePython, ["-m", "venv", environment.path])
        }

        let importCheck = "import lz4.block, capstone, fontTools, nsz, zbic; import sys; sys.version_info < (3, 14) and __import__('backports.zstd')"
        let check = try await Self.runResult(managedPython, ["-c", importCheck])
        guard check.status != 0 else { return managedPython }

        buildMessage = "Installing NXNative Python dependencies…"
        let packages = ["lz4", "capstone>=5,<6", "fonttools", "nsz", "zbic",
                        "backports.zstd; python_version < '3.14'"]
        _ = try await Self.run(managedPython,
                               ["-m", "pip", "install", "--disable-pip-version-check"] + packages)
        return managedPython
    }

    private func startBuild(_ game: Game, python: String) {
        let script = URL(fileURLWithPath: (enginePath as NSString).expandingTildeInPath)
            .appendingPathComponent("scripts/build_ipa_from_nsp.py")
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        let packageDirectory = support.appendingPathComponent("Data/PackageLinks/\(game.id)")
        let workDirectory = support.appendingPathComponent("Data/Builds/\(game.id)")
        let outputDirectory = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath, isDirectory: true)
        let appName = game.name.replacingOccurrences(of: "/", with: "-")
        let output = nextAvailableOutput(from: outputDirectory.appendingPathComponent("\(appName).app"))
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        buildMessage = "Starting build…"
        buildLog = []
        var args = [script.path, packageDirectory.path]
        if !game.usesNUPContainer { args += ["-k", (keysPath as NSString).expandingTildeInPath] }
        if let iconPath = game.buildIconPath,
           FileManager.default.isReadableFile(atPath: iconPath) {
            args += ["--icon", iconPath]
        }
        args += ["--platform", "mac-app", "--progress", "json", "--work-dir", workDirectory.path, "-o", output.path]
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: (enginePath as NSString).expandingTildeInPath)
            environment["PYTHONUNBUFFERED"] = "1"
            process.environment = environment
            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            outputBuffer = ""
            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in self?.consumeBuildOutput(text) }
            }
            process.terminationHandler = { [weak self] task in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                let remaining = outputPipe.fileHandleForReading.readDataToEndOfFile()
                Task { @MainActor in
                    guard let self else { return }
                    if let text = String(data: remaining, encoding: .utf8), !text.isEmpty {
                        self.consumeBuildOutput(text)
                    }
                    self.flushBuildOutput()

                    let result = self.buildResult(exitCode: task.terminationStatus, output: output)
                    if let index = self.games.firstIndex(where: { $0.id == game.id }) {
                        if result.status == "success" {
                            if let bundle = Bundle(url: output),
                               let titleID = NXTitleID.normalize(bundle.object(forInfoDictionaryKey: "DMTitleID") as? String) {
                                self.games[index].titleID = titleID
                            }
                            let previousApps = self.games[index].allCompiledApps.filter { $0.path != output.path }
                            var appsThatCouldNotBeRemoved: [CompiledApp] = []
                            for app in previousApps where FileManager.default.fileExists(atPath: app.fileURL.path) {
                                do { try FileManager.default.removeItem(at: app.fileURL) }
                                catch {
                                    appsThatCouldNotBeRemoved.append(app)
                                    self.buildLog.append("Could not remove old app \(app.fileURL.lastPathComponent): \(error.localizedDescription)")
                                }
                            }
                            self.games[index].builtAppPath = output.path
                            self.games[index].compiledApps = [CompiledApp(path: output.path)] + appsThatCouldNotBeRemoved
                            let cover = workDirectory.appendingPathComponent("icon.jpg")
                            if self.games[index].coverPath == nil, FileManager.default.fileExists(atPath: cover.path) {
                                self.saveBuildIcon(at: cover, for: game.id)
                            }
                        }
                        self.games[index].lastBuildStatus = result.status
                        self.games[index].lastBuildMessage = result.message
                        self.games[index].lastBuildLog = Array(self.buildLog.suffix(160))
                    }
                    self.buildMessage = result.message
                    self.buildLog.append(result.message)
                    if let index = self.games.firstIndex(where: { $0.id == game.id }) {
                        self.games[index].lastBuildLog = Array(self.buildLog.suffix(160))
                    }
                    self.buildGameID = nil
                    self.buildHasStarted = false
                    self.process = nil
                    self.saveLibrary()
                    if result.status == "success" {
                        self.ensureBannerArtwork(for: game.id)
                    }
                }
            }
            try process.run()
            self.process = process
            self.buildHasStarted = true
            if let index = games.firstIndex(where: { $0.id == game.id }) {
                games[index].lastBuildStatus = "building"
                games[index].lastBuildMessage = "NXNative build started."
                games[index].lastBuildLog = []
                saveLibrary()
            }
        } catch {
            buildGameID = nil
            buildHasStarted = false
            markBuildUnavailable(game, reason: "Could not start NXNative: \(error.localizedDescription)")
        }
    }

    func cancelBuild() {
        cancelRequested = true
        buildMessage = "Stopping build…"
        guard let process, process.isRunning else { return }
        process.terminate()
        Task { @MainActor [weak self, weak process] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, let process, self.process === process,
                  self.cancelRequested, process.isRunning else { return }
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    func launch(_ game: Game) {
        guard let app = game.allCompiledApps.first else { return }
        launch(app)
    }

    func launch(_ app: CompiledApp) {
        NSWorkspace.shared.open(app.fileURL)
    }

    func openOutputFolder() {
        let url = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private func consumeBuildOutput(_ text: String) {
        outputBuffer += text
        while let newline = outputBuffer.firstIndex(of: "\n") {
            let line = String(outputBuffer[..<newline])
            outputBuffer.removeSubrange(...newline)
            guard let data = line.data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                if !line.isEmpty { buildLog.append(line) }
                continue
            }
            switch event["ev"] as? String {
            case "stage": buildMessage = event["name"] as? String ?? "Building…"
            case "progress":
                buildMessage = event["name"] as? String ?? "Building…"
                buildFraction = event["frac"] as? Double
            case "say": if let message = event["msg"] as? String { buildLog.append(message) }
            case "game":
                if let name = event["name"] as? String { buildMessage = "Preparing \(name)…" }
                if let iconPath = event["icon"] as? String {
                    let iconURL = URL(fileURLWithPath: (iconPath as NSString).expandingTildeInPath)
                    saveBuildIcon(at: iconURL, for: buildGameID)
                }
            default: break
            }
        }
    }

    private func flushBuildOutput() {
        let finalLine = outputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        outputBuffer = ""
        guard !finalLine.isEmpty else { return }
        if let data = finalLine.data(using: .utf8),
           let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = event["msg"] as? String {
            buildLog.append(message)
        } else {
            buildLog.append(finalLine)
        }
    }

    private func saveBuildIcon(at sourceURL: URL, for gameID: String?) {
        guard let gameID, FileManager.default.fileExists(atPath: sourceURL.path),
              let image = NSImage(contentsOf: sourceURL),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]),
              let index = games.firstIndex(where: { $0.id == gameID }),
              games[index].coverPath == nil else { return }
        let folder = support.appendingPathComponent("Data/Covers", isDirectory: true)
        let destination = folder.appendingPathComponent("\(gameID)-build-icon.png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: destination, options: .atomic)
            games[index].coverPath = destination.path
            saveLibrary()
        } catch {
            buildLog.append("Could not save the game icon: \(error.localizedDescription)")
        }
    }

    private func buildResult(exitCode: Int32, output: URL) -> (status: String, message: String) {
        if cancelRequested { return ("cancelled", "Build cancelled. No app was created.") }
        if exitCode == 0, FileManager.default.fileExists(atPath: output.path) {
            return ("success", "Build complete. The Mac app is ready to play.")
        }
        if exitCode == 0 {
            return ("failed", "NXNative exited successfully, but the expected app was not found at \(output.path).")
        }
        if let errorLine = buildLog.reversed().first(where: { $0.contains("[RED]") }) {
            return ("failed", errorLine.replacingOccurrences(of: "[RED]", with: "Build failed:").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return ("failed", "Build failed with exit code \(exitCode). Review the build log below for details.")
    }

    private func markBuildUnavailable(_ game: Game, reason: String) {
        buildMessage = reason
        buildLog = [reason]
        if let index = games.firstIndex(where: { $0.id == game.id }) {
            games[index].lastBuildStatus = "failed"
            games[index].lastBuildMessage = reason
            games[index].lastBuildLog = [reason]
            saveLibrary()
        }
    }

    private func runCommand(_ executable: String, arguments: [String]) -> (status: Int32, output: String) {
        let command = Process()
        command.executableURL = URL(fileURLWithPath: executable)
        command.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        command.environment = environment
        let pipe = Pipe()
        command.standardOutput = pipe
        command.standardError = pipe
        do {
            try command.run()
            command.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (command.terminationStatus, output)
        } catch {
            return (127, error.localizedDescription)
        }
    }

    private func packageInfo(_ url: URL) -> (titleID: String?, version: String?, role: String, name: String) {
        let name = url.deletingPathExtension().lastPathComponent
        let idRegex = try? NSRegularExpression(pattern: "\\[([0-9A-Fa-f]{16})\\]")
        let range = NSRange(name.startIndex..., in: name)
        let idMatch = idRegex?.firstMatch(in: name, range: range)
        let titleID = idMatch.flatMap { Range($0.range(at: 1), in: name).map { String(name[$0]).uppercased() } }
        let versionRegex = try? NSRegularExpression(pattern: "\\[v(\\d+)\\]", options: [.caseInsensitive])
        let versionMatch = versionRegex?.firstMatch(in: name, range: range)
        let version = versionMatch.flatMap { Range($0.range(at: 1), in: name).map { "v\(name[$0])" } }
        let role = versionMatch == nil ? "unknown" : (version?.lowercased() == "v0" ? "base" : "update")
        let cleaned = name.replacingOccurrences(of: "\\s*\\[[^]]+\\]", with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " _-"))
        return (titleID, version, role, cleaned.isEmpty ? name : cleaned)
    }

    private func stablePackageID(_ url: URL) -> String {
        // Stable, filesystem-safe ID for formats whose title ID is stored inside the container.
        let source = url.standardizedFileURL.path.utf8
        var hash: UInt64 = 14695981039346656037
        for byte in source { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return "nup-\(String(hash, radix: 16))"
    }

    private func baseTitleID(_ id: String?) -> String? {
        guard let id, let value = UInt64(id, radix: 16) else { return id }
        return String(format: "%016llX", value >= 0x800 ? value - 0x800 : value)
    }

    private func nextAvailableOutput(from preferred: URL) -> URL {
        guard FileManager.default.fileExists(atPath: preferred.path) else { return preferred }
        var suffix = 2
        while true {
            let candidate = preferred.deletingLastPathComponent()
                .appendingPathComponent("\(preferred.deletingPathExtension().lastPathComponent) (\(suffix)).app")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            suffix += 1
        }
    }

    private func saveAppIcon(at appURL: URL, identifier: String) -> URL? {
        let image = NSWorkspace.shared.icon(forFile: appURL.path)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let folder = support.appendingPathComponent("Data/Covers", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent("\(identifier)-icon.png")
            try png.write(to: destination, options: .atomic)
            return destination
        } catch { return nil }
    }

    private static func run(_ executable: String, _ arguments: [String]) async throws -> String {
        let result = try await runResult(executable, arguments)
        guard result.status == 0 else {
            throw NSError(domain: "NXManager", code: Int(result.status),
                          userInfo: [NSLocalizedDescriptionKey: result.output.isEmpty ? "The command failed." : result.output])
        }
        return result.output
    }

    private static func runResult(_ executable: String, _ arguments: [String]) async throws -> (status: Int32, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let logURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("nxmanager-command-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let logHandle = try? FileHandle(forWritingTo: logURL)
            process.standardOutput = logHandle ?? FileHandle.nullDevice
            process.standardError = logHandle ?? FileHandle.nullDevice
            process.terminationHandler = { task in
                try? logHandle?.close()
                let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                try? FileManager.default.removeItem(at: logURL)
                continuation.resume(returning: (task.terminationStatus, output))
            }
            do { try process.run() } catch {
                try? logHandle?.close()
                try? FileManager.default.removeItem(at: logURL)
                continuation.resume(throwing: error)
            }
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder }
}
