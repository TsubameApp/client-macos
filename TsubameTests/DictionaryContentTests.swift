import AppKit
import SwiftUI
import Testing
import TsubameCore
@testable import Tsubame

struct DictionaryContentTests {
    @Test func svgRejectsActiveAndExternalContent() {
        #expect(SVGImageValidator.validate(Data(#"<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0L10 10"/></svg>"#.utf8)))
        #expect(SVGImageValidator.validate(Data(#"<svg xmlns="http://www.w3.org/2000/svg"><style>.st0{fill:#fff;font-size:12px}</style><text class="st0" style="font-weight:bold">safe</text></svg>"#.utf8)))
        #expect(SVGImageValidator.validate(Data(#"<svg xmlns="http://www.w3.org/2000/svg"><defs><linearGradient id="g"><stop offset="0" style="stop-color:red"/></linearGradient></defs><rect fill="url(#g)"/></svg>"#.utf8)))
        for body in [
            "<script>alert(1)</script>", "<image href='https://example.com/a.png'/>",
            "<use href='file:///etc/passwd'/>", "<path onclick='bad()'/>",
            "<style>@import url(https://example.com)</style>", "<foreignObject/>"
        ] {
            #expect(!SVGImageValidator.validate(Data("<svg>\(body)</svg>".utf8)))
        }
        #expect(!SVGImageValidator.validate(Data("<!DOCTYPE svg [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><svg>&x;</svg>".utf8)))
    }

    @Test func dictionaryLRUEvictsLeastRecentValueByCost() {
        var cache = DictionaryLRUCache<String, Int>(countLimit: 3, costLimit: 5)
        cache.insert(1, for: "one", cost: 2)
        cache.insert(2, for: "two", cost: 2)
        #expect(cache.value(for: "one") == 1)
        cache.insert(3, for: "three", cost: 2)
        #expect(cache.value(for: "two") == nil)
        #expect(cache.value(for: "one") == 1)
        #expect(cache.value(for: "three") == 3)
        #expect(cache.totalCost == 4)
    }

    @Test func groupsOnlyExactSameDictionaryDefinitionPayloads() async throws {
        func entry(id: Int64, reading: String, data: Data, dictionary: UUID) -> DictionaryLookupEntry {
            .init(dictionaryID: dictionary, dictionaryTitle: "Fixture", sourceRange: .init(start: 0, end: 3),
                  entry: .init(id: id, expression: "今日", reading: reading, definitionTags: id == 1 ? "a" : "b",
                               rules: "", score: 0, sequence: 1, termTags: id == 1 ? "x" : "y", matches: [],
                               definitions: [.init(position: 0, kind: "structured-content", text: nil, contentJSON: data)]))
        }
        let dictionary = UUID(), other = UUID(), same = Data(#"{"content":"same"}"#.utf8)
        let entries = [entry(id: 1, reading: "きょう", data: same, dictionary: dictionary),
                       entry(id: 2, reading: "こんにち", data: same, dictionary: dictionary),
                       entry(id: 3, reading: "こんじつ", data: Data(#"{"content":"different"}"#.utf8), dictionary: dictionary),
                       entry(id: 4, reading: "きょう", data: same, dictionary: other)]
        let articles = try await DictionaryContentService().articles(entries)
        #expect(articles.map(\.variants.count) == [2, 1, 1])
        #expect(articles[0].variants.map(\.entry.id) == [1, 2])
    }

    @Test func loadsLocalImageCachesItAndReadsMetadataOnlySource() async throws {
        let fixture = try ContentFixture()
        defer { fixture.remove() }
        let service = DictionaryContentService()
        let content = try #require(try await service.load(fixture.entry))
        #expect(content.sources.map(\.title) == ["Frequency fixture"])
        #expect(content.sources.first?.metadata.frequencies.first?.value == 7)
        let reference = try #require(content.details.definitions.flatMap(\.nodes).flatMap(\.images).first)
        let loader = DictionaryImageLoader()
        let first = try await loader.load(reference, bundle: fixture.bundle)
        let second = try await loader.load(reference, bundle: fixture.bundle)
        #expect(first.image === second.image)
        #expect(first.image.size.width > 0)
        await loader.invalidate()
        await service.invalidate()
    }

    @Test func cancelledImageLoadDoesNotProduceAnImage() async throws {
        let fixture = try ContentFixture()
        defer { fixture.remove() }
        let nodes = try DictionaryGlossaryDecoder().decode(Data(#"{"type":"image","path":"bird.svg"}"#.utf8))
        let reference = try #require(nodes.flatMap(\.images).first)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DictionaryImageLoader().load(reference, bundle: fixture.bundle)
        }
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError { }
    }

    @Test func rasterImagesAndIdenticalPathsInDifferentBundlesRemainIsolated() async throws {
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII="))
        let first = try ContentFixture(imageData: png, imageName: "bird.png")
        let second = try ContentFixture(imageData: png, imageName: "bird.png")
        defer { first.remove(); second.remove() }
        let reference = try #require(DictionaryGlossaryDecoder().decode(Data(#"{"type":"image","path":"bird.png"}"#.utf8)).flatMap(\.images).first)
        let loader = DictionaryImageLoader()
        let a = try await loader.load(reference, bundle: first.bundle)
        let b = try await loader.load(reference, bundle: second.bundle)
        #expect(a.image !== b.image)
        #expect(a.image.size.width == 1)
    }

    @Test func corruptedImageFailsWithoutHidingDefinitionText() async throws {
        let fixture = try ContentFixture(imageData: Data("not an svg".utf8))
        defer { fixture.remove() }
        let content = try #require(try await DictionaryContentService().load(fixture.entry))
        #expect(content.details.definitions.first?.nodes.map(\.plainText).joined() == "bird")
        let reference = try #require(content.details.definitions.flatMap(\.nodes).flatMap(\.images).first)
        do {
            _ = try await DictionaryImageLoader().load(reference, bundle: fixture.bundle)
            Issue.record("Expected invalid image")
        } catch is DictionaryImageError { }
    }

    @Test @MainActor func nativeGlossaryRendersWithoutWebView() throws {
        let nodes = try DictionaryGlossaryDecoder().decode(Data(#"{"type":"structured-content","content":[{"tag":"div","content":["A ",{"tag":"span","style":{"fontWeight":"bold"},"content":"bird"}]},{"tag":"ruby","content":["鳥",{"tag":"rt","content":"とり"}]},{"tag":"ul","content":[{"tag":"li","content":"a small bird"}]},{"tag":"table","content":[{"tag":"tr","content":[{"tag":"th","content":"Word"},{"tag":"td","content":"鳥"}]}]},{"tag":"details","open":true,"content":[{"tag":"summary","content":"More"},"Detail text"]}]}"#.utf8))
        let renderer = ImageRenderer(content: GlossaryView(nodes: nodes, bundleURL: nil).padding().frame(width: 430))
        let image = try #require(renderer.nsImage)
        #expect(image.size.width == 430)
        #expect(image.size.height > 80)
    }

    @Test func preparedTableKeepsCellStyling() throws {
        let nodes = try DictionaryGlossaryDecoder().decode(Data(##"{"tag":"table","content":[{"tag":"tr","content":[{"tag":"td","style":{"backgroundColor":"#123456","textAlign":"right"},"content":"鳥"}]}]}"##.utf8))
        let table = try #require(PreparedGlossary(nodes: nodes).blocks.first)
        guard case .table(let rows) = table.content else {
            Issue.record("Expected prepared table")
            return
        }
        let cellBlock = try #require(rows.first?.cells.first?.blocks.first)
        #expect(cellBlock.style?.backgroundColor == "#123456")
        #expect(cellBlock.style?.alignment == "right")
    }

    @Test @MainActor func identicalDictionaryImagesSharePresentationState() async throws {
        let fixture = try ContentFixture()
        defer { fixture.remove() }
        let reference = try #require(DictionaryGlossaryDecoder()
            .decode(Data(#"{"type":"image","path":"bird.svg"}"#.utf8))
            .flatMap(\.images).first)
        await DictionaryImageLoader.shared.invalidate()
        let first = DictionaryImagePresentationStore.shared.resource(for: reference, bundleURL: fixture.bundle)
        let second = DictionaryImagePresentationStore.shared.resource(for: reference, bundleURL: fixture.bundle)
        #expect(first === second)
        await DictionaryImageLoader.shared.invalidate()
        let afterInvalidation = DictionaryImagePresentationStore.shared.resource(for: reference, bundleURL: fixture.bundle)
        #expect(first !== afterInvalidation)
    }
}

private struct ContentFixture {
    let root: URL
    let bundle: URL
    let entry: DictionaryLookupEntry

    init(imageData: Data? = nil, imageName: String = "bird.svg") throws {
        root = FileManager.default.temporaryDirectory.appending(path: "TsubameContentTests-\(UUID())")
        let layout = DictionaryLibraryLayout(locations: .init(dataRoot: root.appending(path: "data"), cacheRoot: root.appending(path: "cache"), temporaryRoot: root.appending(path: "tmp")))
        let source = root.appending(path: "source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        do {
            try Data(#"{"title":"Image fixture","format":3,"revision":"1"}"#.utf8).write(to: source.appending(path: "index.json"))
            let terms = #"[["鳥","とり","","",0,["bird",{"type":"image","path":"bird.svg","width":80,"height":40}],0,""]]"#.replacingOccurrences(of: "bird.svg", with: imageName)
            try Data(terms.utf8).write(to: source.appending(path: "term_bank_1.json"))
            try (imageData ?? Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="80" height="40"><style>.st0{fill:red;stroke:#222}</style><rect class="st0" width="80" height="40"/></svg>"#.utf8)).write(to: source.appending(path: imageName))
            let installed = try YomitanDictionaryInstaller(layout: layout).install(from: .init(url: source))
            bundle = installed.bundleURL
            let metadata = root.appending(path: "metadata")
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
            try Data(#"{"title":"Frequency fixture","format":3,"revision":"1"}"#.utf8).write(to: metadata.appending(path: "index.json"))
            try Data(#"[["鳥","freq",7]]"#.utf8).write(to: metadata.appending(path: "term_meta_bank_1.json"))
            let meta = try YomitanDictionaryInstaller(layout: layout).install(from: .init(url: metadata))
            let store = try SQLiteDictionaryStore(databaseURL: installed.databaseURL, contentPolicy: .primary)
            let value = try #require(store.lookup(keys: ["鳥"], limit: 1).first)
            entry = DictionaryLookupEntry(dictionaryID: UUID(), dictionaryTitle: "Image fixture", sourceRange: .init(start: 0, end: 3), entry: value, bundleURL: bundle, metadataBundleURLs: [bundle, meta.bundleURL])
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
