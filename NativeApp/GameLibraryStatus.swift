import AppKit
import Foundation

enum ArtworkSizing {
    private static let imageCache = NSCache<NSString, NSImage>()

    static func aspectFit(source: CGSize, inside container: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / source.width, container.height / source.height)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }

    static func image(at path: String) -> NSImage? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let cacheKey = "\(path)|\(modified)|\(fileSize)" as NSString
        if let cached = imageCache.object(forKey: cacheKey) { return cached }
        guard let source = NSImage(contentsOfFile: path) else { return nil }
        let trimmed = trimTransparentMargins(in: source)
        imageCache.setObject(trimmed, forKey: cacheKey)
        return trimmed
    }

    static func trimTransparentMargins(in image: NSImage, alphaThreshold: CGFloat = 0.03) -> NSImage {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cgImage = bitmap.cgImage else { return image }

        let bytesPerRow = cgImage.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * cgImage.height)
        let didRender = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress,
                                          width: cgImage.width,
                                          height: cgImage.height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                                            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)).rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            return true
        }
        guard didRender else { return image }

        var minX = cgImage.width
        var minY = cgImage.height
        var maxX = -1
        var maxY = -1
        for y in 0..<cgImage.height {
            for x in 0..<cgImage.width {
                guard CGFloat(pixels[(y * cgImage.width + x) * 4 + 3]) / 255 > alphaThreshold else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard maxX >= minX, maxY >= minY,
              minX > 0 || minY > 0 || maxX < cgImage.width - 1 || maxY < cgImage.height - 1,
              let cropped = cgImage.cropping(to: CGRect(x: minX, y: minY,
                                                       width: maxX - minX + 1,
                                                       height: maxY - minY + 1)) else { return image }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }
}

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
