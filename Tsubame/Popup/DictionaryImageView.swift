import AppKit
import ImageIO
import OSLog
import SwiftUI
import TsubameCore

// Constructed on the loader actor, never mutated afterwards; AppKit presentation
// happens on MainActor. The wrapper transfers immutable decoded image ownership.
struct DecodedDictionaryImage: @unchecked Sendable {
    let image: NSImage
}

enum DictionaryImageError: Error, LocalizedError {
    case invalidImage
    case unsafeSVG(String)
    var errorDescription: String? {
        switch self {
        case .invalidImage: "Image decoding failed or dimensions exceed safe limits."
        case .unsafeSVG(let reason): "Unsupported SVG: \(reason)"
        }
    }
}

actor DictionaryImageLoader {
    static let shared = DictionaryImageLoader()
    private let cache = NSCache<NSURL, NSImage>()
    private var resolvers: [URL: DictionaryResourceResolver] = [:]

    init() { cache.totalCostLimit = 24 * 1_024 * 1_024; cache.countLimit = 64 }

    func load(_ reference: DictionaryImageReference, bundle: URL) async throws -> DecodedDictionaryImage {
        try Task.checkCancellation()
        // No suspension between cache lookup and insertion: concurrent requests
        // for the same resource share one decode, independent of glossary work.
        if resolvers[bundle] == nil { resolvers[bundle] = try DictionaryResourceResolver(bundleURL: bundle) }
        let resource = try resolvers[bundle]!.resolve(reference.path)
        if let image = cache.object(forKey: resource.fileURL as NSURL) { return .init(image: image) }
        let interval = TsubameLogging.signposter.beginInterval("ImageDecode")
        defer { TsubameLogging.signposter.endInterval("ImageDecode", interval) }
        let data = try Data(contentsOf: resource.fileURL)
        guard data.count == resource.byteSize, data.count <= 32 * 1_024 * 1_024 else { throw DictionaryImageError.invalidImage }
        let image: NSImage
        if resource.mediaType == "image/svg+xml" {
            let sanitized = try SVGImageValidator.sanitized(data)
            guard let decoded = NSImage(data: sanitized), decoded.size.width.isFinite, decoded.size.height.isFinite,
                  decoded.size.width > 0, decoded.size.height > 0,
                  decoded.size.width <= 4096, decoded.size.height <= 4096 else { throw DictionaryImageError.invalidImage }
            var bounds = CGRect(origin: .zero, size: decoded.size)
            let scale = min(1, 1600 / max(bounds.width, bounds.height))
            bounds.size = .init(width: bounds.width * scale, height: bounds.height * scale)
            guard let raster = decoded.cgImage(forProposedRect: &bounds, context: nil, hints: nil) else { throw DictionaryImageError.invalidImage }
            image = NSImage(cgImage: raster, size: bounds.size)
        } else {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.doubleValue > 0, height.doubleValue > 0,
                  width.doubleValue * height.doubleValue <= 40_000_000,
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1600,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw DictionaryImageError.invalidImage }
            image = NSImage(cgImage: thumbnail, size: .zero)
        }
        try Task.checkCancellation()
        let cost = Int(min(64_000_000, image.size.width * image.size.height * 4))
        cache.setObject(image, forKey: resource.fileURL as NSURL, cost: cost)
        return .init(image: image)
    }

    func invalidate() { cache.removeAllObjects(); resolvers.removeAll() }
}

/// SVG is only accepted as inert local artwork, never as a document with scripts,
/// embedded external images, stylesheet URLs or entity expansion.
struct DictionaryImageView: View {
    let reference: DictionaryImageReference
    let bundleURL: URL?
    @State private var decoded: NSImage?
    @State private var failure: String?

    var body: some View {
        Group {
            if reference.collapsible || reference.collapsed {
                GlossaryDisclosure(title: label, initiallyOpen: !reference.collapsed) { imageContent }
            } else { imageContent }
        }
    }

    private var label: String { reference.title.isEmpty ? reference.path.rawValue : reference.title }

    private var imageContent: some View {
        Group {
            if let decoded {
                Image(nsImage: decoded)
                    .renderingMode(reference.monochrome ? .template : .original)
                    .resizable()
                    .interpolation(reference.pixelated ? .none : .high)
                    .scaledToFit()
                    .frame(maxWidth: desiredWidth, maxHeight: desiredHeight, alignment: .leading)
                    .background(reference.background ? Color.secondary.opacity(0.07) : .clear)
                    .accessibilityLabel(label)
                    .accessibilityIdentifier("dictionary-image")
            } else if let failure {
                Label("Image unavailable", systemImage: "photo.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.secondary).help("\(label): \(failure)")
                    .accessibilityIdentifier("dictionary-image-error")
            } else {
                ProgressView().controlSize(.small).accessibilityLabel("Loading \(label)")
            }
        }
        .frame(width: explicitWidth, height: explicitHeight, alignment: .leading)
        .task(id: "\(bundleURL?.path ?? "")/\(reference.path.rawValue)") {
            decoded = nil
            failure = nil
            guard let bundleURL else { failure = "Dictionary bundle is unavailable."; return }
            do {
                let result = try await DictionaryImageLoader.shared.load(reference, bundle: bundleURL)
                try Task.checkCancellation()
                decoded = result.image
            } catch is CancellationError { }
            catch {
                failure = error.localizedDescription
                TsubameLogging.popup.error("dictionary image failed path=\(reference.path.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private var desiredWidth: CGFloat {
        min(430, reference.width.map { $0 * (reference.sizeUnits == "em" ? 14 : 1) } ?? 430)
    }
    private var explicitWidth: CGFloat? { reference.width.map { min(430, max(1, $0 * (reference.sizeUnits == "em" ? 14 : 1))) } }
    private var explicitHeight: CGFloat? { reference.height.map { min(320, max(1, $0 * (reference.sizeUnits == "em" ? 14 : 1))) } }
    private var desiredHeight: CGFloat {
        min(320, reference.height.map { $0 * (reference.sizeUnits == "em" ? 14 : 1) } ?? 320)
    }
}
