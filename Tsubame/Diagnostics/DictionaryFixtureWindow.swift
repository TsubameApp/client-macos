#if DEBUG
import AppKit
import SwiftUI
import TsubameCore

/// Isolated UI-test fixture: never imports into or changes the user's library.
@MainActor
final class DictionaryFixtureWindow: NSWindowController {
    private let fixtureRoot: URL

    init(fixture: Void = ()) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "TsubameUIFixture-\(UUID())")
        fixtureRoot = root
        do {
            let source = root.appending(path: "source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data(#"{"title":"P0 fixture","format":3,"revision":"1"}"#.utf8).write(to: source.appending(path: "index.json"))
            try Data(#"[["鳥","とり","common","",0,["bird",{"type":"structured-content","content":[{"tag":"ruby","content":["鳥",{"tag":"rt","content":"とり"}]},{"tag":"ul","content":[{"tag":"li","content":"A native dictionary definition"}]},{"tag":"img","path":"bird.svg","width":160,"height":80,"alt":"Dictionary illustration"},{"tag":"details","content":[{"tag":"summary","content":"More details"},"Expanded definition"]}]}],0,"common"]]"#.utf8).write(to: source.appending(path: "term_bank_1.json"))
            try Data(#"[["common","frequency",0,"Common word",0]]"#.utf8).write(to: source.appending(path: "tag_bank_1.json"))
            try Data(#"[["鳥","freq",42],["鳥","pitch",{"reading":"とり","pitches":[{"position":0},{"position":2}]}]]"#.utf8).write(to: source.appending(path: "term_meta_bank_1.json"))
            try Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="160" height="80"><rect width="160" height="80" fill="#e0efff"/><ellipse cx="76" cy="44" rx="35" ry="20" fill="#3984bd"/><circle cx="107" cy="28" r="15" fill="#3984bd"/><circle cx="112" cy="25" r="2"/><path d="M120 28L136 33L120 37Z" fill="#e7a432"/></svg>"##.utf8).write(to: source.appending(path: "bird.svg"))
            let layout = DictionaryLibraryLayout(locations: .init(dataRoot: root.appending(path: "data"), cacheRoot: root.appending(path: "cache"), temporaryRoot: root.appending(path: "tmp")))
            let installed = try YomitanDictionaryInstaller(layout: layout).install(from: .init(url: source))
            let store = try SQLiteDictionaryStore(databaseURL: installed.databaseURL, contentPolicy: .primary)
            guard let value = try store.lookup(keys: ["鳥"], limit: 1).first else { throw DictionaryStoreError.invalidStoredEntry }
            let entry = DictionaryLookupEntry(dictionaryID: UUID(), dictionaryTitle: "P0 fixture", sourceRange: .init(start: 0, end: 3), entry: value, bundleURL: installed.bundleURL)
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 460, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Dictionary P0 fixture"
            window.contentView = NSHostingView(rootView: DictionaryFixtureView(entry: entry))
            super.init(window: window)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    required init?(coder: NSCoder) { nil }
    func cleanUp() { try? FileManager.default.removeItem(at: fixtureRoot) }
}

private struct DictionaryFixtureView: View {
    let entry: DictionaryLookupEntry
    @State private var content: DictionaryContent?
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("鳥 — とり").font(.title)
                if let content {
                    EntryMetadataView(content: content)
                    ForEach(content.preparedDefinitions) { definition in
                        GlossaryView(glossary: definition.glossary, bundleURL: entry.bundleURL)
                    }
                } else if let error { Text(error) }
                else { ProgressView() }
            }.padding().frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            do { content = try await DictionaryContentService.shared.load(entry) }
            catch { self.error = error.localizedDescription }
        }
    }
}
#endif
