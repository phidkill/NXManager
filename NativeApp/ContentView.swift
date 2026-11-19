import AppKit
import Combine
import GameController
import IOKit.hid
import SwiftUI
import UniformTypeIdentifiers

@MainActor private final class ContentViewModel: ObservableObject {
    @Published var search = ""
    @Published var showGame: Game?
    @Published var carouselIndex = 0
    @Published var showSetupWizard = false
    @Published var consoleMode = false
    @Published var gamePendingFullDeletion: Game?
}

@MainActor private final class ImportFormState: ObservableObject {
    @Published var baseURL: URL?
    @Published var updateURL: URL?
    @Published var name = ""
    @Published var folderURL: URL?
}

@MainActor private final class DropZoneState: ObservableObject {
    @Published var isTargeted = false
}

@MainActor private final class ControllerNavigationState: ObservableObject {
    private struct Item {
        let id: String
        let order: Int
        let row: Int
        let column: Int
        let action: () -> Void
    }

    @Published private(set) var focusedID: String?
    @Published var enabled = false
    private var items: [String: Item] = [:]

    func register(id: String, order: Int, row: Int, column: Int, action: @escaping () -> Void) {
        items[id] = Item(id: id, order: order, row: row, column: column, action: action)
        if focusedID == nil { focusedID = orderedItems.first?.id }
    }

    func unregister(id: String) {
        items[id] = nil
        if focusedID == id { focusedID = orderedItems.first?.id }
    }

    func focus(_ id: String) { focusedID = id }

    func isFocused(_ id: String) -> Bool { enabled && focusedID == id && items[id] != nil }

    func move(_ delta: Int) {
        guard let focusedItemID = focusedID, let current = items[focusedItemID] else { return }
        if abs(delta) == 2 {
            let targetColumn = current.column + (delta > 0 ? 1 : -1)
            guard let target = orderedItems.first(where: { $0.row == current.row && $0.column == targetColumn }) else { return }
            focusedID = target.id
            return
        }
        guard abs(delta) == 1 else { return }
        let targetRow = current.row + delta
        let candidates = orderedItems.filter { $0.row == targetRow }
        guard let target = candidates.min(by: { abs($0.column - current.column) < abs($1.column - current.column) }) else { return }
        focusedID = target.id
    }

    func activate() {
        guard let focusedID, let item = items[focusedID] else { return }
        item.action()
    }

    private var orderedItems: [Item] {
        items.values.sorted {
            if $0.row != $1.row { return $0.row < $1.row }
            if $0.column != $1.column { return $0.column < $1.column }
            return $0.order < $1.order
        }
    }
}

private struct ControllerNavigableModifier: ViewModifier {
    @EnvironmentObject private var navigation: ControllerNavigationState
    let id: String
    let order: Int
    let revision: String
    let row: Int
    let column: Int
    let cornerRadius: CGFloat
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(navigation.isFocused(id) ? Color.orange : Color.clear, lineWidth: 2.5)
                    .allowsHitTesting(false)
            }
            .simultaneousGesture(TapGesture().onEnded { navigation.focus(id) })
            .onAppear { navigation.register(id: id, order: order, row: row, column: column, action: action) }
            .onChange(of: revision) { _, _ in navigation.register(id: id, order: order, row: row, column: column, action: action) }
            .onChange(of: row) { _, _ in navigation.register(id: id, order: order, row: row, column: column, action: action) }
            .onChange(of: column) { _, _ in navigation.register(id: id, order: order, row: row, column: column, action: action) }
            .onDisappear { navigation.unregister(id: id) }
    }
}

private extension View {
    func controllerNavigable(id: String, order: Int,
                             revision: String = "",
                             row: Int = 0, column: Int = 0,
                             cornerRadius: CGFloat = 8,
                             action: @escaping () -> Void) -> some View {
        modifier(ControllerNavigableModifier(id: id, order: order, revision: revision,
                                             row: row, column: column, cornerRadius: cornerRadius, action: action))
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var local = ContentViewModel()
    @StateObject private var console = ConsoleInputState()
    @StateObject private var controllerNavigation = ControllerNavigationState()
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @AppStorage("didCompleteSetup") private var didCompleteSetup = false
    @FocusState private var librarySearchFocused: Bool

    private var filteredGames: [Game] {
        guard !local.search.isEmpty else { return model.games }
        return model.games.filter {
            $0.name.localizedCaseInsensitiveContains(local.search)
                || ($0.titleID?.localizedCaseInsensitiveContains(local.search) ?? false)
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch model.appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                HStack(alignment: .top, spacing: 0) {
                    if !local.consoleMode {
                        Color.clear.frame(width: sidebarVisible ? 220 : 0, height: geometry.size.height)
                    }
                    Group {
                        if local.consoleMode {
                            consoleLibraryView
                        } else {
                            switch model.selectedSection ?? .library {
                            case .library: libraryView
                            case .importing: ImportView()
                            case .controller: ControllerView()
                            case .settings: SettingsView()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)

                if !local.consoleMode {
                    sidebarContent(height: geometry.size.height)
                        .frame(width: sidebarVisible ? 220 : 0, height: geometry.size.height, alignment: .topLeading)
                        .clipped()
                        .allowsHitTesting(sidebarVisible)
                        .zIndex(1)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        // Animate the sidebar's width inside the fixed window. NavigationSplitView
        // can resize the native split view itself while restoring its sidebar.
        .toolbar {
            if !local.consoleMode {
                ToolbarItem(placement: .navigation) {
                    Button {
                        sidebarVisible.toggle()
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .help(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: sidebarVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environmentObject(controllerNavigation)
        .sheet(item: $local.showGame) { game in
            GameDetailView(game: game)
                .environmentObject(model)
        }
        .confirmationDialog(
            "Delete \(local.gamePendingFullDeletion?.name ?? "game") and all its data?",
            isPresented: Binding(
                get: { local.gamePendingFullDeletion != nil },
                set: { if !$0 { local.gamePendingFullDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Game and Data", role: .destructive) {
                if let game = local.gamePendingFullDeletion { model.deleteGameCompletely(game) }
                local.gamePendingFullDeletion = nil
            }
            Button("Cancel", role: .cancel) { local.gamePendingFullDeletion = nil }
        } message: {
            Text(local.gamePendingFullDeletion.map { model.fullDeletionSummary(for: $0) } ?? "")
        }
        .sheet(isPresented: Binding(
            get: { local.showSetupWizard && !local.consoleMode },
            set: { if !$0 { local.showSetupWizard = false } }
        )) {
            FirstLaunchSetupView {
                didCompleteSetup = true
                local.showSetupWizard = false
            } onLater: {
                local.showSetupWizard = false
            }
            .environmentObject(model)
        }
        .alert("NXManager", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK", role: .cancel) { model.alertMessage = nil }
        } message: { Text(model.alertMessage ?? "") }
        .preferredColorScheme(preferredColorScheme)
        .onAppear {
            model.checkSetupRequirements()
            if !didCompleteSetup { local.showSetupWizard = true }
            console.refresh()
            if let game = selectedLibraryGame { model.ensureBannerArtwork(for: game.id) }
        }
        .onChange(of: console.hasController) { _, connected in
            if connected, !local.consoleMode {
                setConsoleMode(true)
            } else if !connected, local.consoleMode {
                setConsoleMode(false)
            }
        }
        .onChange(of: local.consoleMode) { _, enabled in
            controllerNavigation.enabled = enabled
            if enabled, let game = selectedLibraryGame {
                controllerNavigation.focus("games.card.\(game.id)")
                synchronizeFocusedGame()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in console.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in console.refresh() }
        .onAppear {
            controllerNavigation.enabled = local.consoleMode
            console.onMove = { direction in
                guard local.consoleMode else { return }
                controllerNavigation.move(direction)
                synchronizeFocusedGame()
            }
            console.onAccept = {
                guard local.consoleMode else { return }
                controllerNavigation.activate()
            }
            console.onBack = {
                guard local.consoleMode else { return }
                setConsoleMode(false)
            }
            console.setActive(true)
        }
        .onChange(of: filteredGames.map(\.id)) { _, ids in
            local.carouselIndex = min(local.carouselIndex, max(ids.count - 1, 0))
        }
    }

    private var selectedLibraryGame: Game? {
        if let selectedGameID = model.selectedGameID, let game = filteredGames.first(where: { $0.id == selectedGameID }) { return game }
        guard !filteredGames.isEmpty else { return nil }
        return filteredGames[min(local.carouselIndex, filteredGames.count - 1)]
    }

    private func synchronizeFocusedGame() {
        guard let focusedID = controllerNavigation.focusedID,
              focusedID.hasPrefix("games.card.") else { return }
        let gameID = String(focusedID.dropFirst("games.card.".count))
        guard let index = model.games.firstIndex(where: { $0.id == gameID }) else { return }
        model.selectedGameID = gameID
        local.carouselIndex = index
    }

    private func sidebarRow(_ title: String, icon: String, section: AppSection) -> some View {
        let selected = model.selectedSection == section
        return Button { model.selectedSection = section } label: {
            HStack(spacing: 13) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold)).frame(width: 22)
                Text(title).font(.system(size: 14, weight: .medium))
                Spacer()
            }
            .foregroundStyle(Color.primary.opacity(selected ? 1 : 0.76))
            .padding(.leading, 15).padding(.trailing, 12).frame(height: 46)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 11))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain).padding(.horizontal, 10)
    }

    private func sidebarContent(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "gamecontroller.fill").font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 38, height: 38)
                    .background(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text("NXManager").font(.headline)
                    Text("GAME LIBRARY").font(.system(size: 9, weight: .bold)).tracking(1.1).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 26).padding(.top, 20).padding(.bottom, 14)
            VStack(spacing: 6) {
                sidebarRow("Games", icon: "square.grid.2x2.fill", section: .library)
                sidebarRow("Import", icon: "square.and.arrow.down.fill", section: .importing)
                sidebarRow("Controller", icon: "gamecontroller.fill", section: .controller)
                sidebarRow("Settings", icon: "gearshape.fill", section: .settings)
            }
            Spacer(minLength: 0)
            HStack(spacing: 9) {
                Circle().fill(model.engineReady ? .green : .orange).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.engineReady ? "Engine ready" : "Setup needed").font(.caption.weight(.semibold))
                    Text("NXNative").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 26).padding(.vertical, 18)
        }
        .frame(width: 224, height: height, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
    }

    private var consoleLibraryView: some View {
        GeometryReader { geometry in
            let playableGames = model.games.filter { !$0.allCompiledApps.isEmpty }
            if playableGames.isEmpty {
                Text("No playable games yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let columns = max(1, Int((geometry.size.width - 80 + 24) / (282 + 24)))
                let rowCount = (playableGames.count + columns - 1) / columns
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button { setConsoleMode(false) } label: {
                            Label("Stop Controller Mode", systemImage: "stop.circle.fill")
                        }
                        .buttonStyle(.bordered)
                        .padding(.horizontal, 26)
                        .padding(.top, 18)
                        .padding(.bottom, 10)
                    }
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            VStack(spacing: 24) {
                                ForEach(0..<rowCount, id: \.self) { row in
                                    let start = row * columns
                                    let end = min(start + columns, playableGames.count)
                                    HStack(spacing: 24) {
                                        ForEach(start..<end, id: \.self) { index in
                                            let game = playableGames[index]
                                            GameLibraryTile(game: game, selected: model.selectedGameID == game.id,
                                                            consoleMode: true, navigationOrder: index,
                                                            navigationRow: row, navigationColumn: index - start) {
                                                model.selectedGameID = game.id
                                                local.carouselIndex = model.games.firstIndex(where: { $0.id == game.id }) ?? index
                                                model.launch(game)
                                            }
                                            .id(game.id)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }
                            .padding(.horizontal, 40)
                            .padding(.vertical, 24)
                        }
                        .scrollIndicators(.hidden)
                        .onChange(of: controllerNavigation.focusedID) { _, id in
                            guard let id, id.hasPrefix("games.card.") else { return }
                            let gameID = String(id.dropFirst("games.card.".count))
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(gameID, anchor: .center)
                            }
                        }
                        .onAppear {
                            let selected = playableGames.first(where: { $0.id == model.selectedGameID }) ?? playableGames.first
                            if let selected {
                                controllerNavigation.focus("games.card.\(selected.id)")
                                synchronizeFocusedGame()
                                proxy.scrollTo(selected.id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var libraryView: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Games").font(.largeTitle.bold())
                    Text("\(model.games.count) games  ·  \(model.games.reduce(0) { $0 + $1.allCompiledApps.count }) compiled apps")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: chooseCompiledApp) {
                    Label("Add Compiled Game", systemImage: "app.badge.plus")
                        .frame(minHeight: 42).contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .help("Choose an existing NXNative Mac game app to add to your library")
                
                Button(action: chooseNewGameFolder) {
                    Label("Add New", systemImage: "plus")
                        .frame(minHeight: 42).contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
                .help("Choose a game folder to add to your library")
                
                Button { setConsoleMode(!local.consoleMode) } label: {
                    Label(local.consoleMode ? "Exit Console Mode" : "Console Mode", systemImage: "gamecontroller")
                        .frame(minHeight: 42).contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .help(local.consoleMode ? "Exit controller navigation mode" : "Enable controller navigation mode")
                
            }
            .contentShape(Rectangle())
            .allowsHitTesting(true)
            .zIndex(10)
            HStack(spacing: 12) {
                TextField("Search games", text: $local.search).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                    .focused($librarySearchFocused)
                    
                Spacer()
                Button { model.openOutputFolder() } label: { Label("Builds Folder", systemImage: "folder") }
                    .buttonStyle(.borderless)
                    
            }
            if model.games.isEmpty {
                ContentUnavailableView {
                    Label("Your library is empty", systemImage: "gamecontroller")
                } description: {
                    Text("Import game files or add a compiled Mac app to get started.")
                } actions: {
                    HStack {
                        Button("Import Game Files") { model.selectedSection = .importing }.buttonStyle(.borderedProminent)
                            
                        Button("Add Compiled Game") { chooseCompiledApp() }.buttonStyle(.bordered)
                            
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredGames.isEmpty {
                ContentUnavailableView.search(text: local.search).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let selected = selectedLibraryGame {
                gameHero(selected)
                Text("YOUR GAMES").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(Array(filteredGames.enumerated()), id: \.element.id) { index, game in
                                GameLibraryTile(game: game, selected: game.id == selected.id, consoleMode: local.consoleMode,
                                                navigationOrder: 300 + index, navigationRow: 0, navigationColumn: index) {
                                    model.selectedGameID = game.id
                                    local.carouselIndex = index
                                }
                                .id(game.id)
                                .contextMenu {
                                    if !game.allCompiledApps.isEmpty { Button("Play") { model.launch(game) } }
                                    Button("Game Details…") { local.showGame = game }
                                    Button("Open Save Folder") { model.openSaveFolder(for: game) }.disabled(game.titleID == nil)
                                    Button("Remove from Library", role: .destructive) { model.removeGame(game) }
                                    Button("Delete Game and Data…", role: .destructive) { local.gamePendingFullDeletion = game }
                                        .disabled(model.buildGameID == game.id)
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: selected.id) { _, id in
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        // Keep the Games header and action buttons at a fixed position while
        // Console Mode changes input handling. Resizing this full-height view
        // made SwiftUI center its content under the title bar on macOS.
        .padding(30)
        .onChange(of: selectedLibraryGame?.id) { _, id in
            model.selectedGameID = id
            if let id { model.ensureBannerArtwork(for: id) }
        }
    }

    private func gameHero(_ game: Game) -> some View {
        let height: CGFloat = 244
        return ZStack {
            if let path = game.bannerPath, let art = NSImage(contentsOfFile: path) {
                Image(nsImage: art).resizable().scaledToFill()
                    .overlay(LinearGradient(colors: [.black.opacity(0.64), .black.opacity(0.10), .black.opacity(0.26)], startPoint: .leading, endPoint: .trailing))
            } else {
                ZStack(alignment: .topTrailing) {
                    LinearGradient(colors: [Color.accentColor.opacity(0.62), Color.black.opacity(0.92)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "gamecontroller.fill").font(.system(size: 150, weight: .regular))
                        .foregroundStyle(.white.opacity(0.07)).padding(.trailing, 52).padding(.top, 28)
                }
            }
            LinearGradient(colors: [.black.opacity(0.12), .black.opacity(0.80)], startPoint: .top, endPoint: .bottom)
            HStack {
                VStack(alignment: .leading, spacing: 11) {
                    Text(game.bannerPath == nil ? (model.artworkLoadingGameIDs.contains(game.id) ? "LOADING GAME ARTWORK" : "GAME LIBRARY") : (game.allCompiledApps.isEmpty ? "READY TO BUILD" : "READY TO PLAY"))
                        .font(.caption.weight(.bold)).tracking(1.4).foregroundStyle(.white.opacity(0.68))
                    Text(game.name).font(.system(size: 31, weight: .bold)).lineLimit(2).foregroundStyle(.white)
                    Text(game.allCompiledApps.isEmpty ? (game.hasBasePackage ? "Your game files are ready to build." : "Add game files to get started.") : "Your game is ready. Pick up where you left off.")
                        .font(.callout).foregroundStyle(.white.opacity(0.76))
                    HStack(spacing: 10) {
                        if !game.allCompiledApps.isEmpty {
                            Button { model.launch(game) } label: { Label("Play", systemImage: "play.fill") }
                                .buttonStyle(.borderedProminent)
                                
                        } else if game.hasBasePackage {
                            Button { local.showGame = game } label: { Label("Build for Mac", systemImage: "hammer.fill") }
                                .buttonStyle(.borderedProminent)
                                
                        }
                        Button("Details") { local.showGame = game }
                            .buttonStyle(.bordered)
                            
                    }.tint(.white)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.15)))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .animation(.easeInOut(duration: 0.22), value: game.id)
    }

    private func chooseCompiledApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        if panel.runModal() == .OK, let url = panel.url { model.importCompiledApp(url) }
    }

    private func chooseNewGameFolder() {
        let panel = NSOpenPanel()
        panel.title = "Add a Game Folder"
        panel.message = "Choose a folder containing the game package files."
        panel.prompt = "Add Game"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.importGameFolder(url)
        }
    }

    private func setConsoleMode(_ enabled: Bool) {
        guard local.consoleMode != enabled else { return }
        let selectedGame = selectedLibraryGame
        local.consoleMode = enabled
        controllerNavigation.enabled = enabled
        if enabled {
            local.search = ""
            local.showGame = nil
            local.gamePendingFullDeletion = nil
            if let selectedGame {
                model.selectedGameID = selectedGame.id
                controllerNavigation.focus("games.card.\(selectedGame.id)")
            }
        }
        if enabled { console.refresh() }
    }
}

private struct GamePoster: View {
    let game: Game
    let isFocused: Bool
    var posterSize: CGFloat = 238

    private var palette: [Color] {
        let colors: [[Color]] = [
            [Color(red: 0.08, green: 0.20, blue: 0.34), Color(red: 0.20, green: 0.49, blue: 0.65)],
            [Color(red: 0.20, green: 0.17, blue: 0.35), Color(red: 0.49, green: 0.34, blue: 0.61)],
            [Color(red: 0.08, green: 0.29, blue: 0.25), Color(red: 0.23, green: 0.55, blue: 0.39)],
            [Color(red: 0.41, green: 0.20, blue: 0.19), Color(red: 0.70, green: 0.43, blue: 0.25)]
        ]
        return colors[Int(UInt(bitPattern: game.id.hashValue) % UInt(colors.count))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .bottomLeading) {
                if let path = game.displayCoverPath, let image = NSImage(contentsOfFile: path) {
                    CoverArtwork(image: image, sourcePath: path, size: posterSize)
                } else {
                    LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: posterSize * 0.22, weight: .light)).foregroundStyle(.white.opacity(0.68))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                    Text(game.name).font(.headline.weight(.semibold)).foregroundStyle(.white).lineLimit(3).padding(14)
                }
                if let badge {
                    Label(badge.title, systemImage: badge.symbol)
                        .font(.system(size: max(10, posterSize * 0.043), weight: .bold)).padding(.horizontal, 11).padding(.vertical, 7)
                        .background(.black.opacity(0.68), in: Capsule()).foregroundStyle(.white)
                        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(width: posterSize, height: posterSize)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isFocused ? Color.accentColor : .clear, lineWidth: 2))
            .shadow(color: .black.opacity(isFocused ? 0.22 : 0.10), radius: isFocused ? 12 : 6, y: 5)
            Text(game.name).font(.system(size: max(17, posterSize * 0.072), weight: .semibold)).lineLimit(1).frame(width: posterSize, alignment: .leading)
            Text(statusDescription)
                .font(.system(size: max(13, posterSize * 0.052))).foregroundStyle(.secondary).lineLimit(1).frame(width: posterSize, alignment: .leading)
        }
        .scaleEffect(isFocused ? 1.015 : 1)
        .contentShape(Rectangle())
    }

    private var badge: (title: String, symbol: String)? {
        switch game.lastBuildStatus {
        case "building": return ("BUILDING", "hammer")
        case "failed": return ("BUILD FAILED", "exclamationmark.triangle.fill")
        case "cancelled": return ("CANCELLED", "xmark.circle.fill")
        default:
            return game.allCompiledApps.isEmpty ? nil : ("READY TO PLAY", "play.fill")
        }
    }

    private var statusDescription: String {
        if game.lastBuildStatus == "building" { return game.lastBuildMessage ?? "Build in progress…" }
        if game.lastBuildStatus == "failed" { return "Build failed · Open Game Details for the log" }
        if game.lastBuildStatus == "cancelled" { return "Build cancelled · Ready to try again" }
        if !game.allCompiledApps.isEmpty { return "\(game.allCompiledApps.count) compiled Mac app\(game.allCompiledApps.count == 1 ? "" : "s") · Ready to play" }
        if game.hasBasePackage { return "Game files imported · Ready to build" }
        return "No game files imported"
    }
}

@MainActor private final class SetupWizardState: ObservableObject {
    @Published var step = 0
}

struct FirstLaunchSetupView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var state = SetupWizardState()
    let onComplete: () -> Void
    let onLater: () -> Void
    private let stepNames = ["Welcome", "Xcode", "Python", "prod.keys", "NXNative", "Ready"]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Label("NXManager Setup", systemImage: "gamecontroller.fill").font(.headline)
                Spacer()
                Text("STEP \(state.step + 1) OF \(stepNames.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(state.step + 1), total: Double(stepNames.count))
            Group {
                switch state.step {
                case 0: welcome
                case 1: xcodeStep
                case 2: pythonStep
                case 3: keysStep
                case 4: engineStep
                default: summary
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Button("Set Up Later", action: onLater).buttonStyle(.plain).foregroundStyle(.secondary)
                    
                Spacer()
                if state.step > 0 {
                    Button("Back") { state.step -= 1 }
                        
                }
                if state.step < stepNames.count - 1 {
                    Button(state.step == 0 ? "Get Started" : "Continue") { state.step += 1 }.buttonStyle(.borderedProminent)
                        
                } else {
                    Button("Open NXManager", action: onComplete).buttonStyle(.borderedProminent)
                        
                }
            }
        }
        .padding(32).frame(width: 660, height: 540)
        .onAppear {
            model.checkSetupRequirements()
            model.refreshEngineStatus()
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Let’s get your Mac ready.").font(.system(size: 30, weight: .bold))
            Text("This guided setup checks the tools NXNative needs, prepares an isolated Python environment, and helps you choose your prod.keys file.")
                .font(.title3).foregroundStyle(.secondary)
            Label("Your keys and game files stay on this Mac.", systemImage: "lock.shield").padding(.top, 8)
        }
    }

    private var xcodeStep: some View {
        requirementStep(title: "Xcode", detail: "NXNative needs Apple's command line tools and SDK to build native Mac apps.", status: model.xcodeMessage, ready: model.xcodeMessage.contains("detected"), symbol: "hammer") {
            Button("Open Apple Developer Downloads") { NSWorkspace.shared.open(URL(string: "https://developer.apple.com/download/all/")!) }
                
            Button("Check Again") { model.checkSetupRequirements() }
                
        }
    }

    private var pythonStep: some View {
        requirementStep(title: "Python and build modules", detail: "NXManager needs Python 3.12 or later. It installs NXNative modules into its own isolated environment.", status: model.setupBusy ? model.setupMessage : model.pythonMessage, ready: model.pythonReady, symbol: "chevron.left.forwardslash.chevron.right") {
            if model.setupBusy {
                ProgressView().controlSize(.small)
                if let start = model.setupStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Elapsed \(elapsed(context.date.timeIntervalSince(start)))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            } else {
                Button("Install / Check Python Modules") { model.prepareSetupPython() }.buttonStyle(.borderedProminent).disabled(!model.pythonReady)
                    
                if !model.pythonReady {
                    Button("Get Python 3.12+") { NSWorkspace.shared.open(URL(string: "https://www.python.org/downloads/macos/")!) }
                        
                }
            }
        }
    }

    private var keysStep: some View {
        requirementStep(title: "Your prod.keys", detail: "Choose the keys file dumped from your own Switch. NXManager checks that it is readable.", status: model.validKeys ? "Readable keys file selected" : "Not configured", ready: model.validKeys, symbol: "key") {
            Button("Choose prod.keys…") {
                let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url { model.keysPath = url.path }
            }
            
        }
    }

    private var engineStep: some View {
        requirementStep(title: "NXNative", detail: "Download or update the open-source engine used to prepare your game builds.", status: model.engineReady ? "NXNative engine detected" : model.engineMessage, ready: model.engineReady, symbol: "cpu") {
            Button(model.engineReady ? "Update NXNative" : "Download NXNative") { model.installOrUpdateEngine() }.buttonStyle(.borderedProminent).disabled(model.engineBusy)
                
            if model.engineBusy { ProgressView("Downloading engine…") }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Setup check").font(.system(size: 27, weight: .bold))
            statusRow("Xcode", ready: model.xcodeMessage.contains("detected"), detail: model.xcodeMessage)
            statusRow("Python 3.12+", ready: model.pythonReady, detail: model.pythonMessage)
            statusRow("Python modules", ready: model.setupMessage == "Python dependencies are ready", detail: model.setupMessage)
            statusRow("prod.keys", ready: model.validKeys, detail: model.validKeys ? "Ready" : "Choose it in Settings")
            statusRow("NXNative", ready: model.engineReady, detail: model.engineMessage)
            Text("Missing items can be configured later in Settings.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func requirementStep<Actions: View>(title: String, detail: String, status: String, ready: Bool, symbol: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: symbol).font(.system(size: 32)).foregroundStyle(Color.accentColor)
            Text(title).font(.system(size: 27, weight: .bold))
            Text(detail).font(.body).foregroundStyle(.secondary)
            Label(status, systemImage: ready ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ready ? Color.green : Color.orange).padding(.top, 5)
            HStack(spacing: 12, content: actions)
        }
    }

    private func statusRow(_ title: String, ready: Bool, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : "minus.circle").foregroundStyle(ready ? Color.green : Color.secondary)
            VStack(alignment: .leading) { Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer()
        }
    }

    private func elapsed(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds)); return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

struct ImportView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var form = ImportFormState()

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Import Games").font(.largeTitle.bold())
                    Text("Add source packages to build with NXNative, or add an existing Mac app to your library.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            Section {
                HStack(spacing: 8) {
                    Text("Build a Game").font(.headline)
                    Button { showFolderInfo() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.plain).help("What to put in the game folder")
                        
                }
                FolderDropZone(folder: form.folderURL, onChoose: chooseGameFolder) { url in
                    importFolder(url)
                }
                Text("Choose a folder with XCI/NSP packages, or a folder containing one Switch 2 NUP file. NUP builds do not need prod.keys.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Label("prod.keys · Switch 1", systemImage: model.validKeys ? "key.fill" : "key")
                    Spacer()
                    Text(model.validKeys ? "Configured" : "Optional for NUP").foregroundStyle(model.validKeys ? .green : .secondary)
                    Button("Settings…") { model.selectedSection = .settings }
                        
                }
            }

            Section("Add a Compiled Mac App") {
                Button { chooseCompiledApp() } label: {
                    Label("Choose an NXNative Game App…", systemImage: "app.dashed")
                }
                
                Text("Only NXNative game apps with a valid 16-character DMTitleID are added. The app is added as soon as you choose it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
        .padding(28)
    }

    private func showFolderInfo() {
        let alert = NSAlert()
        alert.messageText = "Prepare a game folder"
        alert.informativeText = "For Switch games, put the base package and optional update/DLC files in one folder. For Switch 2, use a folder containing one .nup file. NXNative reads the NUP metadata and does not need prod.keys for it."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func importFolder(_ url: URL) {
        form.folderURL = url
        if model.importGameFolder(url) { form.folderURL = nil }
    }

    private func chooseGameFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { importFolder(url) }
    }

    private func chooseCompiledApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        if panel.runModal() == .OK, let url = panel.url { model.importCompiledApp(url) }
    }

    private func choosePackage(asUpdate: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["xci", "nsp", "nsz", "xcz", "nup"].compactMap {
            UTType(filenameExtension: $0, conformingTo: .data)
        }
        if panel.runModal() == .OK, let url = panel.url { receivePackage(url, asUpdate: asUpdate) }
    }

    private func receivePackage(_ url: URL, asUpdate: Bool) {
        guard ["xci", "nsp", "nsz", "xcz", "nup"].contains(url.pathExtension.lowercased()) else {
            model.alertMessage = "Choose an XCI, NSP, NSZ, XCZ, or NUP game package."
            return
        }
        if asUpdate {
            form.updateURL = url
        } else {
            form.baseURL = url
            if form.name.isEmpty { form.name = inferredName(url) }
        }
    }

    private func inferredName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "\\s*\\[[^]]+\\]", with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " _-"))
    }
}

private struct FolderDropZone: View {
    let folder: URL?
    let onChoose: () -> Void
    let onDropFolder: (URL) -> Void
    @StateObject private var state = DropZoneState()

    var body: some View {
        Button(action: onChoose) {
            VStack(spacing: 10) {
                Image(systemName: folder == nil ? "folder.badge.plus" : "checkmark.circle.fill")
                    .font(.system(size: 30)).foregroundStyle(folder == nil ? Color.secondary : Color.green)
                Text(folder?.lastPathComponent ?? "Choose or drop a game folder")
                    .font(.headline).lineLimit(1).truncationMode(.middle)
                Text(state.isTargeted ? "Drop folder to import" : "Game files · optional update · optional DLC")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 146)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .background(folder == nil ? Color.clear : Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(state.isTargeted ? Color.accentColor : Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: state.isTargeted ? 2 : 1, dash: folder == nil ? [6, 5] : [])))
        }
        .buttonStyle(.plain)
        
        .onDrop(of: [UTType.fileURL], isTargeted: $state.isTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadObject(ofClass: NSURL.self) { item, _ in
                guard let url = item as? URL else { return }
                Task { @MainActor in
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
                    onDropFolder(url)
                }
            }
            return true
        }
    }
}

struct ControllerView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var state = ControllerListState()
    @State private var selectedGameID = ""
    @State private var selectedHIDControllerID = ""
    @FocusState private var profileNameFocused: Bool

    private var gamesWithTitleID: [Game] { model.games.filter { $0.titleID != nil } }
    private var selectedGame: Game? { gamesWithTitleID.first { $0.id == selectedGameID } }
    private var rawControllers: [ControllerListState.DetectedController] { state.devices.filter { !$0.isGameController } }
    private var selectedHIDControllerName: String? { rawControllers.first { $0.id == selectedHIDControllerID }?.name }

    private func loadSelection() {
        guard let titleID = selectedGame?.titleID else { return }
        state.selectedTitleID = titleID.uppercased()
        state.loadProfiles()
        state.loadMapping(titleID: titleID)
        state.refreshLog(titleID: titleID, controllerName: selectedHIDControllerName)
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Controller").font(.largeTitle.bold())
                    Text("Detect connected controllers and check whether NXNative can remap their input.")
                        .foregroundStyle(.secondary)
                }.padding(.vertical, 8)
            }
            Section("Connected Controllers") {
                if state.devices.isEmpty {
                    Label("No controllers detected", systemImage: "gamecontroller")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.devices) { controller in
                        HStack {
                            Image(systemName: "gamecontroller.fill").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(controller.name)
                                Text(controller.transport).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(controller.isGameController ? "GameController" : "HID detected")
                                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        }
                    }
                }
                HStack {
                    Button("Refresh Controllers") { state.refresh() }
                        
                    Text(state.refreshMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Console Menu Mapping") {
                Picker("Profile for Console Mode", selection: $state.consoleMenuProfileID) {
                    Text("Default controller mapping").tag("")
                    ForEach(state.profiles) { profile in
                        Text("\(profile.name) · \(profile.controllerName)").tag(profile.id)
                    }
                }
                .disabled(state.profiles.isEmpty)
                
                Text(state.consoleMenuProfileID.isEmpty
                     ? "Choose a saved raw-HID profile to use its A and B assignments for Console Mode. This setting is independent of each game’s profile. GameController devices keep Apple’s native mapping."
                     : "The selected raw-HID profile’s A assignment confirms and B assignment goes back in Console Mode. Its per-game mapping remains unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("NXNative HID Mapping") {
                Text("Calibrate every button, D-pad direction, trigger, stick click and stick direction in sequence. NXNative applies button mappings from the selected game’s env.txt.")
                    .font(.callout).foregroundStyle(.secondary)
                if rawControllers.isEmpty {
                    Label("Connect a raw HID controller to calibrate it. macOS GameController devices use Apple’s native mapping and cannot be remapped here.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Raw HID controller", selection: $selectedHIDControllerID) {
                        ForEach(rawControllers) { controller in Text(controller.name).tag(controller.id) }
                    }
                    .onChange(of: selectedHIDControllerID) { _, _ in loadSelection() }
                    
                }
                if gamesWithTitleID.isEmpty {
                    Label("Import a game with a valid title ID before configuring a mapping.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Picker("Game", selection: $selectedGameID) {
                        ForEach(gamesWithTitleID) { game in Text(game.name).tag(game.id) }
                    }
                    .onChange(of: selectedGameID) { _, _ in loadSelection() }
                    
                    TextField("Profile name", text: $state.profileName).textFieldStyle(.roundedBorder)
                        .focused($profileNameFocused)
                        
                    if !state.profilesForSelectedGame.isEmpty {
                        Picker("Saved profile", selection: $state.selectedProfileID) {
                            ForEach(state.profilesForSelectedGame) { profile in
                                Text("\(profile.name) · \(profile.controllerName)").tag(profile.id)
                            }
                        }
                        
                        HStack {
                            Button("Apply Saved Profile to Game") {
                                _ = state.applySavedProfile(id: state.selectedProfileID, titleID: selectedGame?.titleID)
                            }
                            
                            Button("Use This Profile for Console Mode") {
                                state.applyProfileToConsoleMenu(id: state.selectedProfileID)
                            }
                            .disabled(!state.profiles.contains(where: { $0.id == state.selectedProfileID }))
                            
                        }
                    }

                    if state.calibrationRunning, let step = state.currentCalibrationStep {
                        VStack(alignment: .leading, spacing: 12) {
                            ProgressView(value: Double(state.calibrationStepIndex), total: Double(ControllerCalibrationStep.all.count))
                            HStack(alignment: .center, spacing: 14) {
                                Text(step.title).font(.system(size: 26, weight: .bold)).frame(minWidth: 130, alignment: .leading)
                                Text(step.instruction).font(.title3).foregroundStyle(.secondary)
                            }
                            Text(state.calibrationMessage).font(.callout).foregroundStyle(state.currentStepSupported == false ? .orange : .secondary)
                            HStack {
                                Text("Step \(state.calibrationStepIndex + 1) of \(ControllerCalibrationStep.all.count)")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Spacer()
                                Button("Cancel Calibration", role: .cancel) { state.cancelCalibration() }
                                    
                            }
                        }
                        .padding(14)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                    } else if state.calibrationComplete {
                        Label("Calibration complete · \(state.supportedInputCount) inputs match NXNative", systemImage: state.unsupportedInputCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(state.unsupportedInputCount == 0 ? .green : .orange)
                        if state.unsupportedInputCount > 0 {
                            Text("\(state.unsupportedInputCount) axis or hat inputs do not match NXNative’s supported HID layout. They are marked Mapping impossible in the profile; button remaps remain usable.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        HStack {
                            Button("Start Again") { state.resetCalibration() }
                                
                            Button("Save Profile & Apply to Game") {
                                _ = state.saveCalibrationProfile(titleID: selectedGame?.titleID,
                                    controllerName: selectedHIDControllerName ?? "Raw HID Controller",
                                    controllerID: selectedHIDControllerID)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(state.profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            
                        }
                    } else {
                        Button("Start Controller Setup") {
                            guard let controller = rawControllers.first(where: { $0.id == selectedHIDControllerID }) else { return }
                            state.startCalibration(controller: controller)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedHIDControllerID.isEmpty)
                        
                    }
                    Text(state.mappingStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
        .padding(28)
        .onAppear {
            state.refresh()
            state.loadProfiles()
            if selectedGameID.isEmpty { selectedGameID = gamesWithTitleID.first?.id ?? "" }
            if selectedHIDControllerID.isEmpty { selectedHIDControllerID = rawControllers.first?.id ?? "" }
            loadSelection()
        }
        .onChange(of: state.devices) { _, devices in
            if !devices.contains(where: { $0.id == selectedHIDControllerID }) {
                selectedHIDControllerID = devices.first(where: { !$0.isGameController })?.id ?? ""
            }
            loadSelection()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            state.refresh(discoverWireless: false)
            state.refreshLog(titleID: selectedGame?.titleID, controllerName: selectedHIDControllerName)
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in state.refresh(discoverWireless: false) }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in state.refresh(discoverWireless: false) }
        .onDisappear { state.cancelCalibration() }
    }

    private static func nextValue(in values: [String], after current: String) -> String {
        guard !values.isEmpty else { return current }
        let index = values.firstIndex(of: current) ?? -1
        return values[(index + 1) % values.count]
    }
}

@MainActor private final class ControllerListState: ObservableObject {
    fileprivate struct DetectedController: Identifiable, Equatable {
        let id: String
        let name: String
        let transport: String
        let isGameController: Bool
        let vendorID: Int
        let productID: Int
        let locationID: Int?
        let axisUsages: Set<String>
    }

    @Published var devices: [DetectedController] = []
    @Published var refreshMessage = "Not checked yet"
    @Published var mapping: [String: String] = [:]
    @Published var loggingEnabled = false
    @Published var mappingStatus = "Choose a game to configure its controller mapping."
    @Published var recentUsages: [Int] = []
    @Published var profiles: [ControllerMappingProfile] = []
    @Published var selectedProfileID = ""
    @Published var consoleMenuProfileID = UserDefaults.standard.string(forKey: "consoleMenuProfileID") ?? "" {
        didSet { UserDefaults.standard.set(consoleMenuProfileID, forKey: "consoleMenuProfileID") }
    }
    @Published var profileName = "New Controller Profile"
    @Published private(set) var calibrationRunning = false
    @Published private(set) var calibrationComplete = false
    @Published private(set) var calibrationStepIndex = 0
    @Published private(set) var calibrationMessage = "Start setup to begin listening for controller input."
    @Published private(set) var capturedInputs: [String: CapturedHIDInput] = [:]
    @Published private(set) var compatibility: [String: Bool] = [:]
    @Published private(set) var buttonUsages: [String: String] = [:]
    private var discoveryTask: Task<Void, Never>?
    private let rawCapture = RawHIDControllerCapture()
    private let profileURL = ControllerProfileStore.fileURL()
    private var stickAxisValues: [String: Double] = [:]
    private var pendingNeutralAxes: Set<String> = []
    private var awaitingStickNeutral = false

    var currentCalibrationStep: ControllerCalibrationStep? {
        guard calibrationRunning, ControllerCalibrationStep.all.indices.contains(calibrationStepIndex) else { return nil }
        return ControllerCalibrationStep.all[calibrationStepIndex]
    }
    var currentStepSupported: Bool? { currentCalibrationStep.flatMap { compatibility[$0.id] } }
    var profilesForSelectedGame: [ControllerMappingProfile] {
        profiles.filter { $0.gameTitleID == selectedTitleID }
    }
    var selectedTitleID: String?
    var supportedInputCount: Int { compatibility.values.filter { $0 }.count }
    var unsupportedInputCount: Int { compatibility.values.filter { !$0 }.count }

    func refresh(discoverWireless: Bool = true) {
        devices = Self.detectedControllers()
        refreshMessage = "Checked just now · \(devices.count) found"
        guard discoverWireless else { return }
        GCController.startWirelessControllerDiscovery { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.devices = Self.detectedControllers()
                self.refreshMessage = "Checked just now · \(self.devices.count) found"
            }
        }
        discoveryTask?.cancel()
        discoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            GCController.stopWirelessControllerDiscovery()
            self?.devices = Self.detectedControllers()
            if let self { self.refreshMessage = "Checked just now · \(self.devices.count) found" }
        }
    }

    func loadMapping(titleID: String) {
        do {
            let url = try NXNativeHIDConfiguration.envFile(titleID: titleID)
            let values = NXNativeHIDConfiguration.read(url)
            mapping = NXNativeHIDConfiguration.parseMap(values["DM_HID_MAP"])
            loggingEnabled = values["DM_HID_LOG"] == "1"
            mappingStatus = "Profile: \(url.path) · \(mapping.count) custom button mapping(s)"
            refreshLog(titleID: titleID, controllerName: nil)
        } catch {
            mappingStatus = error.localizedDescription
        }
    }

    @discardableResult
    func saveMapping(titleID: String?) -> Bool {
        guard let titleID else {
            mappingStatus = "Select a game with a valid title ID first."
            return false
        }
        do {
            let map = try NXNativeHIDConfiguration.serializedMap(mapping)
            let url = try NXNativeHIDConfiguration.envFile(titleID: titleID)
            try NXNativeHIDConfiguration.update(url, mapping: map, logEnabled: loggingEnabled)
            mappingStatus = "Saved to \(url.path) · \(map ?? "using NXNative defaults")"
            return true
        } catch {
            mappingStatus = error.localizedDescription
            return false
        }
    }

    func refreshLog(titleID: String?, controllerName: String?) {
        guard let titleID, let url = try? NXNativeHIDConfiguration.logFile(titleID: titleID),
              let log = NXNativeHIDConfiguration.readLogTail(url) else {
            recentUsages = []
            return
        }
        recentUsages = NXNativeHIDConfiguration.recentButtonUsages(in: log, controllerName: controllerName)
    }

    func assign(usage: Int, to button: String) {
        mapping[button] = String(usage)
        mappingStatus = "Usage \(usage) assigned to \(button). Save Mapping to apply it to the selected game."
    }

    func openLog(titleID: String?) {
        guard let titleID, let url = try? NXNativeHIDConfiguration.logFile(titleID: titleID) else {
            mappingStatus = "Select a game with a valid title ID first."
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            mappingStatus = "No game log yet. Save with HID logging enabled, launch the game, then press controller buttons."
            return
        }
        NSWorkspace.shared.open(url)
    }

    fileprivate static func detectedControllers() -> [DetectedController] {
        let gameControllers = GCController.controllers().map { controller in
            DetectedController(id: "gc-\(ObjectIdentifier(controller))",
                               name: controller.vendorName ?? "Game Controller",
                               transport: controller.productCategory,
                               isGameController: true, vendorID: 0, productID: 0,
                               locationID: nil, axisUsages: [])
        }
        let gameControllerNames = Set(gameControllers.map { $0.name.localizedLowercase })
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        // CopyDevices can enumerate matching devices without opening the HID
        // interfaces. Opening often fails for sandboxed apps and is not needed
        // just to show a connected controller in the list.
        guard let matched = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return gameControllers
        }
        let hidControllers = matched.compactMap { device -> DetectedController? in
            guard let page = integerProperty(device, kIOHIDPrimaryUsagePageKey),
                  let usage = integerProperty(device, kIOHIDPrimaryUsageKey),
                  page == 0x01, [0x04, 0x05, 0x08].contains(usage) else { return nil }
            let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String)
                ?? "USB/Bluetooth HID Controller"
            guard !gameControllerNames.contains(name.localizedLowercase) else { return nil }
            let vendor = integerProperty(device, kIOHIDVendorIDKey) ?? 0
            let product = integerProperty(device, kIOHIDProductIDKey) ?? 0
            let location = integerProperty(device, kIOHIDLocationIDKey)
            let transport = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String)
                ?? "HID"
            let axisUsages = axisUsageSet(device)
            return DetectedController(id: "hid-\(vendor)-\(product)-\(location ?? 0)-\(name)", name: name,
                                      transport: "Raw HID · \(transport)", isGameController: false,
                                      vendorID: vendor, productID: product, locationID: location,
                                      axisUsages: axisUsages)
        }
        return gameControllers + hidControllers
    }

    private static func axisUsageSet(_ device: IOHIDDevice) -> Set<String> {
        guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else { return [] }
        return Set(elements.compactMap { element in
            let page = IOHIDElementGetUsagePage(element)
            let usage = IOHIDElementGetUsage(element)
            guard (page == 0x01 && (0x30...0x35).contains(usage)) || (page == 0x02 && [0xC4, 0xC5].contains(usage)) else { return nil }
            return "\(page):\(usage)"
        })
    }

    private static func integerProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    func loadProfiles() {
        profiles = ControllerProfileStore.load(from: profileURL)
        if !consoleMenuProfileID.isEmpty && !profiles.contains(where: { $0.id == consoleMenuProfileID }) {
            consoleMenuProfileID = ""
        }
        if !profilesForSelectedGame.contains(where: { $0.id == selectedProfileID }) {
            selectedProfileID = profilesForSelectedGame.first?.id ?? ""
        }
    }

    func applyProfileToConsoleMenu(id: String) {
        guard let profile = profiles.first(where: { $0.id == id }) else {
            mappingStatus = "Choose a saved controller profile first."
            return
        }
        guard Int(profile.buttonUsages["A"] ?? "") != nil,
              Int(profile.buttonUsages["B"] ?? "") != nil else {
            mappingStatus = "This profile has no calibrated A and B buttons, so it cannot control Console Mode."
            return
        }
        consoleMenuProfileID = profile.id
        mappingStatus = "Profile ‘\(profile.name)’ is now used for Console Mode. A confirms and B goes back."
    }

    func startCalibration(controller: DetectedController) {
        guard !controller.isGameController else {
            mappingStatus = "Mapping impossible: this controller uses macOS GameController. NXNative’s DM_HID_MAP applies only to raw HID controllers."
            return
        }
        do {
            capturedInputs = [:]
            compatibility = [:]
            buttonUsages = [:]
            stickAxisValues = [:]
            pendingNeutralAxes = []
            awaitingStickNeutral = false
            calibrationStepIndex = 0
            calibrationComplete = false
            calibrationMessage = "Opening the controller for calibration…"
            profileName = "\(controller.name) Layout"
            try rawCapture.start(vendorID: controller.vendorID, productID: controller.productID,
                                 locationID: controller.locationID) { [weak self] input in
                self?.consume(input, axisUsages: controller.axisUsages)
            }
            calibrationRunning = true
            calibrationMessage = "Listening to \(controller.name). Press or move only the highlighted control."
        } catch {
            calibrationRunning = false
            calibrationMessage = error.localizedDescription
            mappingStatus = error.localizedDescription
        }
    }

    func cancelCalibration() {
        rawCapture.stop()
        calibrationRunning = false
    }

    func resetCalibration() {
        cancelCalibration()
        calibrationComplete = false
        calibrationStepIndex = 0
        capturedInputs = [:]
        compatibility = [:]
        buttonUsages = [:]
        stickAxisValues = [:]
        pendingNeutralAxes = []
        awaitingStickNeutral = false
        calibrationMessage = "Start setup to begin listening for controller input."
    }

    private func consume(_ input: CapturedHIDInput, axisUsages: Set<String>) {
        guard calibrationRunning, let step = currentCalibrationStep else { return }
        let axisKey = "\(input.page):\(input.usage)"
        if input.kind == .axis, input.page == 0x01, (0x30...0x35).contains(input.usage) {
            stickAxisValues[axisKey] = normalized(input)
        }
        if awaitingStickNeutral {
            guard input.kind == .axis, pendingNeutralAxes.contains(axisKey) else { return }
            let stillMoving = pendingNeutralAxes.contains { abs(stickAxisValues[$0] ?? 0) > 0.20 }
            guard !stillMoving else { return }
            awaitingStickNeutral = false
            pendingNeutralAxes.removeAll()
            calibrationMessage = "Stick returned to center."
            advanceCalibration()
            return
        }
        let target = step.id.replacingOccurrences(of: "button.", with: "")
            .replacingOccurrences(of: "axis.", with: "")
        if step.kind == .stickAxis {
            guard input.kind == .axis else { return }
            let value = normalized(input)
            guard abs(value) >= 0.65 else { return }
            let expected = expectedAxis(for: target, axisUsages: axisUsages)
            let matches = input.page == expected.page && input.usage == expected.usage && (value * Double(expected.sign)) > 0.65
            capturedInputs[step.id] = input
            compatibility[step.id] = matches
            let resultMessage = matches
                ? "Detected HID axis \(input.page):\(input.usage). NXNative maps this stick direction automatically."
                : "Detected HID axis \(input.page):\(input.usage), but NXNative expects \(expected.page):\(expected.usage) in this direction. Mapping impossible for this axis."
            pendingNeutralAxes = stickAxes(for: target, axisUsages: axisUsages)
            pendingNeutralAxes.insert(axisKey)
            if pendingNeutralAxes.contains(where: { abs(stickAxisValues[$0] ?? 0) > 0.20 }) {
                awaitingStickNeutral = true
                calibrationMessage = resultMessage + " Return the stick to center to continue."
            } else {
                calibrationMessage = resultMessage
                pendingNeutralAxes.removeAll()
                advanceCalibration()
            }
            return
        }

        if input.kind == .button, input.value > 0 {
            guard (1...32).contains(input.usage) else { return }
            if let duplicate = buttonUsages.first(where: { $0.value == String(input.usage) && $0.key != target }) {
                calibrationMessage = "Usage \(input.usage) is already assigned to \(duplicate.key). Release it, then press the requested control."
                return
            }
            buttonUsages[target] = String(input.usage)
            capturedInputs[step.id] = input
            compatibility[step.id] = true
            calibrationMessage = "HID button usage \(input.usage) assigned to \(target)."
            advanceCalibration()
            return
        }

        if input.kind == .hat, let direction = hatDirection(input) {
            guard ["UP", "DOWN", "LEFT", "RIGHT"].contains(target) else { return }
            let expected: [String: Int] = ["UP": 0, "RIGHT": 2, "DOWN": 4, "LEFT": 6]
            let matches = direction == expected[target]
            capturedInputs[step.id] = input
            compatibility[step.id] = matches
            calibrationMessage = matches
                ? "D-pad \(target) detected on the standard HID hat. NXNative maps it automatically."
                : "This hat reports direction \(direction), not \(target). NXNative does not rotate HID hats. Mapping impossible for this direction."
            advanceCalibration()
            return
        }

        if input.kind == .axis, (target == "ZL" || target == "ZR") {
            let value = normalized(input)
            guard value >= 0.65 else { return }
            let expectedUsage = target == "ZL" ? 0xC5 : 0xC4
            let matches = input.page == 0x02 && input.usage == expectedUsage
            capturedInputs[step.id] = input
            compatibility[step.id] = matches
            calibrationMessage = matches
                ? "Analog trigger axis detected. NXNative maps this trigger automatically."
                : "Detected HID axis \(input.page):\(input.usage); NXNative expects \(target == "ZL" ? "2:197" : "2:196"). Mapping impossible for this trigger axis."
            advanceCalibration()
        }
    }

    private func advanceCalibration() {
        if calibrationStepIndex + 1 < ControllerCalibrationStep.all.count {
            calibrationStepIndex += 1
            if let step = currentCalibrationStep { calibrationMessage += " Next: \(step.instruction)" }
        } else {
            rawCapture.stop()
            calibrationRunning = false
            calibrationComplete = true
            calibrationStepIndex = ControllerCalibrationStep.all.count
            calibrationMessage = "All \(ControllerCalibrationStep.all.count) inputs have been checked. Review any Mapping impossible results, then save the profile."
        }
    }

    private func normalized(_ input: CapturedHIDInput) -> Double {
        guard input.logicalMax > input.logicalMin else { return 0 }
        return 2 * (input.value - Double(input.logicalMin)) / Double(input.logicalMax - input.logicalMin) - 1
    }

    private func hatDirection(_ input: CapturedHIDInput) -> Int? {
        let direction = Int(input.value) - input.logicalMin
        guard (0..<8).contains(direction) else { return nil }
        return direction
    }

    private func expectedAxis(for target: String, axisUsages: Set<String>) -> (page: Int, usage: Int, sign: Int) {
        switch target {
        case "LS_UP": return (0x01, 0x31, -1)
        case "LS_DOWN": return (0x01, 0x31, 1)
        case "LS_LEFT": return (0x01, 0x30, -1)
        case "LS_RIGHT": return (0x01, 0x30, 1)
        case "RS_UP": return (0x01, axisUsages.contains("1:50") ? 0x35 : 0x34, -1)
        case "RS_DOWN": return (0x01, axisUsages.contains("1:50") ? 0x35 : 0x34, 1)
        case "RS_LEFT": return (0x01, axisUsages.contains("1:50") ? 0x32 : 0x33, -1)
        default: return (0x01, axisUsages.contains("1:50") ? 0x32 : 0x33, 1)
        }
    }

    private func stickAxes(for target: String, axisUsages: Set<String>) -> Set<String> {
        if target.hasPrefix("LS_") { return Set(["1:48", "1:49"].filter { axisUsages.contains($0) }) }
        let right = axisUsages.contains("1:50") ? ["1:50", "1:53"] : ["1:51", "1:52"]
        return Set(right.filter { axisUsages.contains($0) })
    }

    @discardableResult
    func saveCalibrationProfile(titleID: String?, controllerName: String, controllerID: String) -> Bool {
        guard calibrationComplete, let titleID else {
            mappingStatus = "Finish calibration and select a game with a valid title ID first."
            return false
        }
        do {
            let profile = ControllerMappingProfile(id: UUID().uuidString, name: profileName.trimmingCharacters(in: .whitespacesAndNewlines),
                gameTitleID: titleID.uppercased(), controllerName: controllerName, controllerID: controllerID,
                createdAt: Date(), buttonUsages: buttonUsages, capturedInputs: capturedInputs,
                compatibility: compatibility)
            profiles = try ControllerProfileStore.save(profile, to: profileURL)
            selectedProfileID = profile.id
            let map = try NXNativeHIDConfiguration.serializedMap(buttonUsages)
            let env = try NXNativeHIDConfiguration.envFile(titleID: titleID)
            try NXNativeHIDConfiguration.update(env, mapping: map, logEnabled: false)
            mappingStatus = "Profile ‘\(profile.name)’ saved and applied to \(titleID.uppercased()). Button mappings were written to \(env.path)."
            return true
        } catch {
            mappingStatus = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func applySavedProfile(id: String, titleID: String?) -> Bool {
        guard let titleID, let profile = profiles.first(where: { $0.id == id }) else {
            mappingStatus = "Select a saved profile for the current game."
            return false
        }
        do {
            let map = try NXNativeHIDConfiguration.serializedMap(profile.buttonUsages)
            let env = try NXNativeHIDConfiguration.envFile(titleID: titleID)
            try NXNativeHIDConfiguration.update(env, mapping: map, logEnabled: false)
            mappingStatus = "Profile ‘\(profile.name)’ applied to \(titleID.uppercased())."
            return true
        } catch {
            mappingStatus = error.localizedDescription
            return false
        }
    }
}

@MainActor private final class ConsoleInputState: ObservableObject {
    @Published private(set) var controllers: [GCController] = []
    @Published private(set) var rawHIDControllerDetected = false
    @Published private(set) var rawCaptureIssue: String?
    var hasController: Bool { !controllers.isEmpty || rawHIDControllerDetected }
    var onMove: ((Int) -> Void)?
    var onAccept: (() -> Void)?
    var onBack: (() -> Void)?
    private var directionPads: [ObjectIdentifier: Int] = [:]
    private var rawCapture: RawHIDControllerCapture?
    private var rawControllerID: String?
    private var rawAxisDirections: [String: Int] = [:]
    private var rawButtonStates: [Int: Bool] = [:]
    private var menuProfileID: String?
    private var menuButtonUsages: [String: String] = [:]
    private var rawHatDirection = -1
    private var discoveryTimer: Timer?
    private var active = false

    func setActive(_ active: Bool) {
        self.active = active
        discoveryTimer?.invalidate()
        discoveryTimer = nil
        guard active else {
            rawCapture?.stop()
            rawCapture = nil
            rawControllerID = nil
            rawCaptureIssue = nil
            rawAxisDirections.removeAll()
            rawButtonStates.removeAll()
            rawHatDirection = -1
            return
        }
        refresh()
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func refresh() {
        controllers = GCController.controllers()
        refreshMenuProfile()
        directionPads.removeAll()
        for controller in controllers {
            controller.extendedGamepad?.valueChangedHandler = { [weak self] gamepad, element in
                let pad: GCControllerDirectionPad?
                if element === gamepad.dpad || element === gamepad.dpad.left || element === gamepad.dpad.right
                    || element === gamepad.dpad.up || element === gamepad.dpad.down {
                    pad = gamepad.dpad
                } else if element === gamepad.leftThumbstick || element === gamepad.leftThumbstick.xAxis
                            || element === gamepad.leftThumbstick.yAxis {
                    pad = gamepad.leftThumbstick
                } else if element === gamepad.rightThumbstick || element === gamepad.rightThumbstick.xAxis
                            || element === gamepad.rightThumbstick.yAxis {
                    pad = gamepad.rightThumbstick
                } else {
                    pad = nil
                }
                if let pad {
                    let id = ObjectIdentifier(pad)
                    let x = pad.xAxis.value, y = pad.yAxis.value
                    let direction = abs(x) > abs(y) && abs(x) >= 0.65 ? (x < 0 ? -2 : 2)
                        : abs(y) >= 0.65 ? (y > 0 ? -1 : 1) : 0
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let previous = self.directionPads[id, default: 0]
                        self.directionPads[id] = direction
                        if direction != 0 && direction != previous { self.onMove?(direction) }
                    }
                    return
                }
                guard let button = element as? GCControllerButtonInput, button.isPressed else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if element === gamepad.dpad.left { self.onMove?(-2) }
                    else if element === gamepad.dpad.right { self.onMove?(2) }
                    else if element === gamepad.dpad.up { self.onMove?(-1) }
                    else if element === gamepad.dpad.down { self.onMove?(1) }
                    else if element === gamepad.buttonA { self.onAccept?() }
                    else if element === gamepad.buttonB { self.onBack?() }
                }
            }
        }
        refreshRawCapture()
    }

    private func refreshRawCapture() {
        guard active else { return }
        guard let device = ControllerListState.detectedControllers().first(where: { !$0.isGameController }) else {
            rawHIDControllerDetected = false
            rawCapture?.stop()
            rawCapture = nil
            rawControllerID = nil
            rawCaptureIssue = nil
            return
        }
        rawHIDControllerDetected = true
        guard device.id != rawControllerID else { return }
        rawCapture?.stop()
        let capture = RawHIDControllerCapture()
        do {
            try capture.start(vendorID: device.vendorID, productID: device.productID, locationID: device.locationID) { [weak self] input in
                self?.handleRawInput(input)
            }
            rawCapture = capture
            rawControllerID = device.id
            rawCaptureIssue = nil
            rawAxisDirections.removeAll()
            rawButtonStates.removeAll()
            rawHatDirection = -1
        } catch {
            rawCapture = nil
            rawControllerID = nil
            rawCaptureIssue = "Manette HID indisponible : \(error.localizedDescription)"
        }
    }

    private func handleRawInput(_ input: CapturedHIDInput) {
        if input.kind == .button {
            refreshMenuProfile()
            // NXNative documents A=2/B=1 as its 8BitDo D-input default;
            // a saved controller profile overrides those usage numbers.
            let acceptUsage = Int(menuButtonUsages["A"] ?? "2") ?? 2
            let backUsage = Int(menuButtonUsages["B"] ?? "1") ?? 1
            let pressed = input.value > 0
            let wasPressed = rawButtonStates[input.usage, default: false]
            rawButtonStates[input.usage] = pressed
            if pressed && !wasPressed && input.usage == acceptUsage { onAccept?() }
            else if pressed && !wasPressed && input.usage == backUsage { onBack?() }
            return
        }
        if input.kind == .hat, input.page == 0x01, input.usage == 0x39 {
            let offset = Int(input.value) - input.logicalMin
            let direction: Int
            switch offset {
            case 0: direction = -1         // up
            case 1, 2: direction = 2       // up-right, right
            case 3, 4: direction = 1       // down-right, down
            case 5, 6: direction = -2      // down-left, left
            case 7: direction = -1        // up-left
            default: direction = 0         // centered
            }
            if offset != rawHatDirection, direction != 0 { onMove?(direction) }
            rawHatDirection = offset
            return
        }
        guard input.kind == .axis, input.page == 0x01, (0x30...0x35).contains(input.usage),
              input.logicalMax > input.logicalMin else { return }
        let value = 2 * (input.value - Double(input.logicalMin)) / Double(input.logicalMax - input.logicalMin) - 1
        let direction: Int
        let horizontal = input.usage == 0x30 || input.usage == 0x32 || input.usage == 0x33
        direction = value < -0.65 ? (horizontal ? -2 : -1) : value > 0.65 ? (horizontal ? 2 : 1) : 0
        let key = "\(input.page):\(input.usage)"
        let previous = rawAxisDirections[key, default: 0]
        rawAxisDirections[key] = direction
        if direction != 0 && direction != previous { onMove?(direction) }
    }

    private func refreshMenuProfile() {
        let selectedID = UserDefaults.standard.string(forKey: "consoleMenuProfileID") ?? ""
        guard selectedID != menuProfileID else { return }
        menuProfileID = selectedID
        guard !selectedID.isEmpty else {
            menuButtonUsages = [:]
            return
        }
        menuButtonUsages = ControllerProfileStore.load(from: ControllerProfileStore.fileURL())
            .first(where: { $0.id == selectedID })?.buttonUsages ?? [:]
    }
}

private struct PackageDropZone: View {
    @StateObject private var state = DropZoneState()
    let title: String
    let subtitle: String?
    let emptyHint: String
    let footnote: String
    let symbol: String
    let onClear: () -> Void
    let onChoose: () -> Void
    let onDrop: (URL) -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onChoose) {
                VStack(spacing: 8) {
                    Image(systemName: subtitle == nil ? symbol : "checkmark.circle.fill")
                        .font(.system(size: 25, weight: .regular))
                        .foregroundStyle(state.isTargeted ? Color.accentColor : subtitle == nil ? Color.secondary : Color.green)
                    Text(title).font(.headline)
                    if let subtitle {
                        Text("File selected").font(.caption.weight(.semibold)).foregroundStyle(.green)
                        Text(subtitle).font(.caption).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                    } else {
                        Text(emptyHint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(state.isTargeted ? "Release to add" : footnote)
                        .font(.caption2).foregroundStyle(subtitle == nil ? Color.secondary.opacity(0.75) : Color.green.opacity(0.85))
                }
                .frame(maxWidth: .infinity, minHeight: 132)
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .background(subtitle == nil ? Color.clear : Color.green.opacity(0.09),
                            in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(state.isTargeted ? Color.accentColor : subtitle == nil ? Color.secondary.opacity(0.42) : Color.green.opacity(0.8),
                                      style: StrokeStyle(lineWidth: state.isTargeted || subtitle != nil ? 2 : 1.2,
                                                         dash: subtitle == nil && !state.isTargeted ? [6, 5] : []))
                }
            }
            .buttonStyle(.plain)
            if subtitle != nil {
                Button(action: onClear) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Remove selected file")
                .padding(7)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $state.isTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadObject(ofClass: NSURL.self) { item, _ in
                guard let url = item as? URL else { return }
                Task { @MainActor in onDrop(url) }
            }
            return true
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Settings").font(.largeTitle.bold())
                    Text("Choose the app appearance and configure NXNative and your build folders.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
            Section("Appearance") {
                Picker("Theme", selection: $model.appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                
                Text("Dark mode follows macOS automatically when System is selected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Keys") {
                PathSettingRow(title: "prod.keys", detail: model.keysPath,
                               icon: model.validKeys ? "checkmark.circle.fill" : "key") {
                    chooseFile { model.keysPath = $0.path }
                }
                Text("The file stays on this Mac. NXManager checks that it is readable, but does not inspect its contents.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("NXNative Engine") {
                PathSettingRow(title: model.engineMessage, detail: model.enginePath, icon: "cpu") {
                    chooseDirectory { model.enginePath = $0.path; model.refreshEngineStatus() }
                }
                HStack {
                    Link("NXNative Documentation", destination: URL(string: "https://github.com/seedds/nxnative")!)
                        
                    Spacer()
                    Button(model.engineMessage.contains("not found") ? "Install NXNative" : "Update Engine") {
                        model.installOrUpdateEngine()
                    }
                    .disabled(model.engineBusy)
                    
                }
                if model.engineBusy { ProgressView("Downloading engine…") }
            }
            Section("Compiled Apps") {
                PathSettingRow(title: "Build Output Folder", detail: model.outputPath, icon: "folder") {
                    chooseDirectory { model.outputPath = $0.path }
                }
                Text("Apps built here remain separate from NXManager and can be opened from Finder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("App", value: "NXManager for macOS")
                LabeledContent("Interface", value: "SwiftUI")
                LabeledContent("Architecture", value: "Apple Silicon")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
        .padding(28)
    }

    private static func nextAppearance(after value: String) -> String {
        let choices = ["system", "light", "dark"]
        let index = choices.firstIndex(of: value) ?? 0
        return choices[(index + 1) % choices.count]
    }

    private func chooseFile(_ onSelect: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { onSelect(url) }
    }

    private func chooseDirectory(_ onSelect: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { onSelect(url) }
    }
}

private struct CoverArtwork: View {
    let image: NSImage
    let sourcePath: String
    let size: CGFloat

    private var isAppIcon: Bool {
        let filename = URL(fileURLWithPath: sourcePath).lastPathComponent.lowercased()
        return filename.hasSuffix("-icon.png") || filename.contains("-build-icon.")
    }

    var body: some View {
        Image(nsImage: image).resizable().scaledToFill()
            .frame(width: size, height: size)
            .scaleEffect(isAppIcon ? 1.2 : 1)
            .frame(width: size, height: size)
            .clipped()
    }
}

private struct GameLibraryTile: View {
    let game: Game
    let selected: Bool
    let consoleMode: Bool
    let navigationOrder: Int
    let navigationRow: Int
    let navigationColumn: Int
    let action: () -> Void
    private var size: CGFloat { consoleMode ? 260 : 154 }
    private var cardWidth: CGFloat { size + 22 }
    private var status: GameLibraryStatus {
        GameLibraryStatus(lastBuildStatus: game.lastBuildStatus,
                          hasCompiledApp: !game.allCompiledApps.isEmpty,
                          hasBasePackage: game.hasBasePackage)
    }
    private var statusColor: Color {
        switch status {
        case .failed: .red
        case .readyToPlay: .green
        case .notBuilt: .secondary
        case .building, .readyToBuild: .orange
        }
    }
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    if let path = game.displayCoverPath, let image = NSImage(contentsOfFile: path) {
                        CoverArtwork(image: image, sourcePath: path, size: size)
                    } else {
                        ZStack {
                            Color.accentColor.opacity(0.75)
                            Image(systemName: "gamecontroller.fill").font(.system(size: 40)).foregroundStyle(.white.opacity(0.45))
                        }.frame(width: size, height: size)
                    }
                    Text(status.title).font(.system(size: consoleMode ? 11 : 9, weight: .bold)).padding(.horizontal, 9).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule()).foregroundStyle(statusColor).padding(8)
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text(game.name).font(.system(size: consoleMode ? 15 : 13, weight: .bold)).lineLimit(1)
                    .foregroundStyle(.primary)
                    .frame(width: cardWidth - 20, alignment: .leading)
            }
            .padding(10)
            .frame(width: cardWidth, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(selected ? 1 : 0.72),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(selected ? (consoleMode ? Color.orange.opacity(0.65) : Color.accentColor.opacity(0.4)) : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 1)
            }
            .shadow(color: .black.opacity(selected && !consoleMode ? 0.15 : 0.06), radius: selected && !consoleMode ? 10 : 4, y: 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .controllerNavigable(id: "games.card.\(game.id)", order: navigationOrder,
                             revision: "\(game.name)|\(game.allCompiledApps.count)|\(game.lastBuildStatus ?? "none")",
                             row: navigationRow, column: navigationColumn,
                             cornerRadius: 22, action: action)
    }
}

private struct PathSettingRow: View {
    let title: String
    let detail: String
    let icon: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
            }
            Spacer(minLength: 18)
            Button("Choose…", action: action)
                
        }
    }
}

struct GameDetailView: View {
    @EnvironmentObject private var model: AppModel
    let game: Game
    @Environment(\.dismiss) private var dismiss
    @State private var confirmFullDeletion = false
    @State private var titleDraft = ""

    private var current: Game { model.games.first(where: { $0.id == game.id }) ?? game }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 20) {
                GamePoster(game: current, isFocused: true, posterSize: 230).frame(width: 230)
                VStack(alignment: .leading, spacing: 13) {
                    HStack(spacing: 8) {
                        TextField("Game title", text: $titleDraft)
                            .font(.system(size: 27, weight: .bold))
                            .textFieldStyle(.plain)
                            .onSubmit { model.renameGame(current.id, to: titleDraft) }
                        Button("Save") { model.renameGame(current.id, to: titleDraft) }
                            .buttonStyle(.bordered)
                            .disabled(titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || titleDraft == current.name)
                    }
                    if let titleID = current.titleID {
                        Label(titleID, systemImage: "number").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    buildStatusLabel
                    if let message = current.lastBuildMessage, current.lastBuildStatus != "building" {
                        Text(message).font(.callout).foregroundStyle(current.lastBuildStatus == "failed" ? Color.red : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button { choosePoster() } label: { Label("Choose Custom Library Cover…", systemImage: "photo") }
                        .buttonStyle(.borderless)
                    Text("Changes the library poster only. It does not change the built app’s icon.")
                        .font(.caption).foregroundStyle(.secondary)
                    if current.apiCoverPath != nil {
                        Button { model.useOnlineCoverAsCover(for: current.id) } label: {
                            Label("Use Online Game Cover", systemImage: "globe")
                        }
                        .buttonStyle(.borderless)
                    }
                    if current.titleID != nil {
                        Button {
                            model.ensureBannerArtwork(for: current.id, forceLookup: true)
                        } label: {
                            Label(model.artworkLoadingGameIDs.contains(current.id) ? "Searching Online…" : "Search Online Artwork", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.artworkLoadingGameIDs.contains(current.id))
                    } else {
                        Text("Online artwork lookup becomes available after NXNative reads the game’s Title ID.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let artworkMessage = model.artworkMessages[current.id] {
                        Text(artworkMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    Button { chooseBuildIcon() } label: {
                        Label(current.buildIconPath == nil ? "Choose Icon for Next Build…" : "Change Icon for Next Build…", systemImage: "app.dashed")
                    }
                    .buttonStyle(.borderless)
                    if current.buildIconPath != nil {
                        HStack(spacing: 8) {
                            Label("Custom icon is set for the next build.", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                            Button("Reset to Source Icon") { model.resetBuildIcon(for: current.id) }
                                .buttonStyle(.borderless)
                                .help("Clear the custom icon so the next build uses the icon from the game files.")
                        }
                    } else {
                        Text("The next build uses the icon provided by the source game files.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                        
                    Divider()
                    ForEach(current.allCompiledApps) { app in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(app.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                Text(app.version.map { "Version \($0)" } ?? app.fileURL.path)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("Play") { model.launch(app) }.buttonStyle(.borderedProminent)
                                
                            Button { NSWorkspace.shared.activateFileViewerSelecting([app.fileURL]) } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless).help("Show in Finder")
                            
                        }
                    }
                    if !current.packages.isEmpty {
                        Divider()
                        ForEach(current.packages) { item in
                            HStack(spacing: 8) {
                                Image(systemName: "shippingbox").foregroundStyle(.secondary)
                                Text(item.role == "base" ? "Base Game" : item.role == "update" ? "Update" : "Package")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                            Text(item.fileURL.lastPathComponent).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            if model.buildGameID == current.id {
                ProgressView(value: model.buildFraction).progressViewStyle(.linear)
                HStack { Text(model.buildMessage).foregroundStyle(.secondary); Spacer();
                    Button("Cancel") { model.cancelBuild() }
                        
                }
                ScrollView {
                    Text(model.buildLog.suffix(12).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 90)
            } else if let lines = current.lastBuildLog, !lines.isEmpty,
                      current.lastBuildStatus == "failed" || current.lastBuildStatus == "cancelled" {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Build Log").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ScrollView {
                        Text(lines.suffix(14).joined(separator: "\n"))
                            .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 88)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                }
            }
            HStack {
                if current.hasBasePackage && current.allCompiledApps.isEmpty {
                    Button { model.build(current) } label: {
                        Label(model.buildGameID == current.id
                              ? (model.buildHasStarted ? "Building…" : "Preparing…")
                              : "Build for Mac", systemImage: "hammer")
                    }
                        .buttonStyle(.borderedProminent).disabled(model.buildGameID != nil)
                } else if current.hasBasePackage && current.buildIconPath != nil {
                    Button { model.build(current) } label: {
                        Label(model.buildGameID == current.id
                              ? (model.buildHasStarted ? "Building…" : "Preparing…")
                              : "Rebuild with Icon", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent).disabled(model.buildGameID != nil)
                } else if current.buildIconPath != nil && !current.hasBasePackage {
                    Text("Import the original game files to rebuild with this icon.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button { model.openSaveFolder(for: current) } label: { Label("Open Save Folder", systemImage: "folder") }
                    .disabled(current.titleID == nil)
                    
                Spacer()
                Button("Remove from Library", role: .destructive) { model.removeGame(current); dismiss() }
                    
                Button("Delete Game and Data…", role: .destructive) { confirmFullDeletion = true }
                    .disabled(model.buildGameID == current.id)
                    
                Button("Done") { dismiss() }
                    
            }
        }
        .confirmationDialog("Delete \(current.name) and all its data?", isPresented: $confirmFullDeletion, titleVisibility: .visible) {
            Button("Delete Game and Data", role: .destructive) {
                model.deleteGameCompletely(current)
                dismiss()
            }
            
            Button("Cancel", role: .cancel) {}
                
        } message: {
            Text(model.fullDeletionSummary(for: current))
        }
        .padding(32)
        .frame(width: 790, height: 620)
        .onAppear { titleDraft = current.name }
    }

    @ViewBuilder private var buildStatusLabel: some View {
        switch current.lastBuildStatus {
        case "building":
            Label("Building…", systemImage: "hammer").foregroundStyle(.orange)
        case "failed":
            Label("Build Failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case "cancelled":
            Label("Build Cancelled", systemImage: "xmark.circle").foregroundStyle(.secondary)
        default:
            if !current.allCompiledApps.isEmpty {
                Label("Ready to Play", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if current.hasBasePackage {
                Label("Game Files Imported · Ready to Build", systemImage: "shippingbox").foregroundStyle(.secondary)
            } else {
                Label("No Game Files Imported", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            }
        }
    }

    private func choosePoster() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg]
        if panel.runModal() == .OK, let url = panel.url { model.setCover(for: current.id, from: url) }
    }

    private func chooseBuildIcon() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg]
        if panel.runModal() == .OK, let url = panel.url { model.setBuildIcon(for: current.id, from: url) }
    }
}

private func inferredName(_ url: URL) -> String {
    url.deletingPathExtension().lastPathComponent
        .replacingOccurrences(of: "\\s*\\[[^]]+\\]", with: "", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: " _-"))
}
