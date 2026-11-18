import Foundation

enum GameLibraryStatus: Equatable {
    case building
    case failed
    case readyToPlay
    case readyToBuild
    case notBuilt

    init(lastBuildStatus: String?, hasCompiledApp: Bool, hasBasePackage: Bool) {
        if lastBuildStatus == "building" { self = .building }
        else if lastBuildStatus == "failed" { self = .failed }
        else if hasCompiledApp { self = .readyToPlay }
        else if hasBasePackage { self = .readyToBuild }
        else { self = .notBuilt }
    }

    var title: String {
        switch self {
        case .building: "BUILDING"
        case .failed: "ERROR"
        case .readyToPlay: "READY TO PLAY"
        case .readyToBuild: "READY TO BUILD"
        case .notBuilt: "NOT BUILT"
        }
    }
}
