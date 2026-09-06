import AppKit
import ImageIO
import OSLog
import SwiftUI
import TsubameCore

// Constructed on the loader actor, never mutated afterwards; AppKit presentation
// happens on MainActor. The wrapper transfers immutable decoded image ownership.
struct DecodedDictionaryImage: @unchecked Sendable {
    let image: NSImage
    let cost: Int
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
        if let image = cache.object(forKey: resource.fileURL as NSURL) {
            return .init(image: image, cost: Self.cost(of: image))
        }
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
        let cost = Self.cost(of: image)
        cache.setObject(image, forKey: resource.fileURL as NSURL, cost: cost)
        return .init(image: image, cost: cost)
    }

    func invalidate() async {
        cache.removeAllObjects()
        resolvers.removeAll()
        await DictionaryImagePresentationStore.shared.invalidate()
    }

    private static func cost(of image: NSImage) -> Int {
        let pixels = image.representations.map { representation in
            max(1, representation.pixelsWide) * max(1, representation.pixelsHigh)
        }.max() ?? Int(max(1, image.size.width) * max(1, image.size.height))
        return min(64_000_000, pixels * 4)
    }
}

/// SVG is only accepted as inert local artwork, never as a document with scripts,
/// embedded external images, stylesheet URLs or entity expansion.
@MainActor @Observable
final class DictionaryImageResource {
    enum Phase {
        case loading
        case loaded(NSImage)
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private var task: Task<Void, Never>?
    private let didLoad: (DictionaryImageResource, Int) -> Void

    init(didLoad: @escaping (DictionaryImageResource, Int) -> Void) {
        self.didLoad = didLoad
    }

    func load(_ reference: DictionaryImageReference, bundleURL: URL?) {
        guard task == nil else { return }
        guard let bundleURL else {
            phase = .failed("Dictionary bundle is unavailable.")
            return
        }
        task = Task { [weak self] in
            do {
                let result = try await DictionaryImageLoader.shared.load(reference, bundle: bundleURL)
                try Task.checkCancellation()
                self?.phase = .loaded(result.image)
                if let self { didLoad(self, result.cost) }
            } catch is CancellationError {
                self?.task = nil
            } catch {
                self?.phase = .failed(error.localizedDescription)
                TsubameLogging.popup.error("dictionary image failed path=\(reference.path.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

@MainActor
final class DictionaryImagePresentationStore {
    static let shared = DictionaryImagePresentationStore()
    private let resources = NSCache<NSString, DictionaryImageResource>()
    private let activeResources = NSHashTable<DictionaryImageResource>.weakObjects()

    private init() {
        resources.countLimit = 128
        resources.totalCostLimit = 32 * 1_024 * 1_024
    }

    func resource(for reference: DictionaryImageReference, bundleURL: URL?) -> DictionaryImageResource {
        let key = key(reference, bundleURL: bundleURL) as NSString
        if let resource = resources.object(forKey: key) { return resource }
        let resource = DictionaryImageResource { [weak self] resource, cost in
            self?.resources.setObject(resource, forKey: key, cost: cost)
        }
        resources.setObject(resource, forKey: key, cost: 1)
        activeResources.add(resource)
        return resource
    }

    func preload<S: Sequence>(_ references: S, bundleURL: URL?) where S.Element == DictionaryImageReference {
        for reference in references {
            resource(for: reference, bundleURL: bundleURL).load(reference, bundleURL: bundleURL)
        }
    }

    func invalidate() {
        activeResources.allObjects.forEach { $0.cancel() }
        resources.removeAllObjects()
        activeResources.removeAllObjects()
    }

    private func key(_ reference: DictionaryImageReference, bundleURL: URL?) -> String {
        "\(bundleURL?.path ?? "")\u{0}\(reference.path.rawValue)"
    }
}

@MainActor
struct DictionaryImageView: View {
    let reference: DictionaryImageReference
    let bundleURL: URL?
    @State private var resource: DictionaryImageResource

    init(reference: DictionaryImageReference, bundleURL: URL?) {
        self.reference = reference
        self.bundleURL = bundleURL
        _resource = State(initialValue: DictionaryImagePresentationStore.shared.resource(for: reference, bundleURL: bundleURL))
    }

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
            switch resource.phase {
            case .loaded(let decoded):
                Image(nsImage: decoded)
                    .renderingMode(reference.monochrome ? .template : .original)
                    .resizable()
                    .interpolation(reference.pixelated ? .none : .high)
                    .scaledToFit()
                    .frame(maxWidth: desiredWidth, maxHeight: desiredHeight, alignment: .leading)
                    .background(reference.background ? Color.secondary.opacity(0.07) : .clear)
                    .accessibilityLabel(label)
                    .accessibilityIdentifier("dictionary-image")
            case .failed(let failure):
                Label("Image unavailable", systemImage: "photo.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.secondary).help("\(label): \(failure)")
                    .accessibilityIdentifier("dictionary-image-error")
            case .loading:
                ProgressView().controlSize(.small).accessibilityLabel("Loading \(label)")
            }
        }
        .frame(width: explicitWidth, height: explicitHeight, alignment: .leading)
        .onChange(of: resourceKey, initial: true) { _, _ in
            let next = DictionaryImagePresentationStore.shared.resource(for: reference, bundleURL: bundleURL)
            if resource !== next { resource = next }
            next.load(reference, bundleURL: bundleURL)
        }
    }

    private var resourceKey: String {
        "\(bundleURL?.path ?? "")\u{0}\(reference.path.rawValue)"
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
