import AppKit
import SwiftUI
import TsubameCore

struct PreparedGlossaryDefinition: Sendable, Identifiable {
    let position: Int
    let glossary: PreparedGlossary
    var id: Int { position }
}

struct PreparedGlossary: Sendable {
    let blocks: [PreparedGlossaryBlock]

    init(nodes: [GlossaryNode]) {
        blocks = GlossaryPreparer.blocks(nodes, path: [])
    }
}

struct PreparedGlossaryBlock: Sendable, Identifiable {
    let id: String
    let content: Content
    let style: GlossaryStyle?
    let title: String

    indirect enum Content: Sendable {
        case inline([PreparedGlossaryInlineRun])
        case image(DictionaryImageReference)
        case container([PreparedGlossaryBlock])
        case details(title: String, initiallyOpen: Bool, blocks: [PreparedGlossaryBlock])
        case list(ordered: Bool, items: [PreparedGlossaryListItem])
        case ruby(base: String, reading: String)
        case table([PreparedGlossaryTableRow])
    }
}

struct PreparedGlossaryInlineRun: Sendable, Identifiable {
    let id: String
    let content: Content

    enum Content: Sendable {
        case text(AttributedString)
        case image(DictionaryImageReference)
    }
}

struct PreparedGlossaryListItem: Sendable, Identifiable {
    let id: String
    let blocks: [PreparedGlossaryBlock]
}

struct PreparedGlossaryTableRow: Sendable, Identifiable {
    let id: String
    let cells: [PreparedGlossaryTableCell]
}

struct PreparedGlossaryTableCell: Sendable, Identifiable {
    let id: String
    let blocks: [PreparedGlossaryBlock]
    let columnSpan: Int
}

private enum GlossaryPreparer {
    static func blocks(_ nodes: [GlossaryNode], path: [Int]) -> [PreparedGlossaryBlock] {
        var result: [PreparedGlossaryBlock] = []
        var inlineRuns: [PreparedGlossaryInlineRun] = []
        var text = AttributedString()
        var textID: String?

        func flushText() {
            guard !text.characters.isEmpty else { return }
            inlineRuns.append(.init(id: textID ?? id(path, suffix: "text"), content: .text(text)))
            text = AttributedString()
            textID = nil
        }
        func flushInline() {
            flushText()
            guard !inlineRuns.isEmpty else { return }
            result.append(.init(id: inlineRuns[0].id + ":inline", content: .inline(inlineRuns), style: nil, title: ""))
            inlineRuns = []
        }

        for (index, node) in nodes.enumerated() {
            let nodePath = path + [index]
            if let value = inlineText(node) {
                if textID == nil { textID = id(nodePath, suffix: "text") }
                text += value
            } else if case .image(let image) = node, image.sizeUnits == "em", (image.height ?? 99) <= 3 {
                flushText()
                inlineRuns.append(.init(id: id(nodePath, suffix: "image"), content: .image(image)))
            } else {
                flushInline()
                result.append(block(node, path: nodePath))
            }
        }
        flushInline()
        return result
    }

    private static func block(_ node: GlossaryNode, path: [Int]) -> PreparedGlossaryBlock {
        switch node {
        case .text(let text):
            return .init(id: id(path, suffix: "text"), content: .inline([.init(id: id(path, suffix: "run"), content: .text(AttributedString(text)))]), style: nil, title: "")
        case .lineBreak:
            return .init(id: id(path, suffix: "break"), content: .inline([.init(id: id(path, suffix: "run"), content: .text(AttributedString("\n")))]), style: nil, title: "")
        case .image(let reference):
            return .init(id: id(path, suffix: "image"), content: .image(reference), style: nil, title: "")
        case .element(let element):
            let content: PreparedGlossaryBlock.Content
            switch element.tag {
            case "details":
                let summaryIndex = element.children.firstIndex { node in
                    if case .element(let child) = node { return child.tag == "summary" }
                    return false
                }
                let summary = summaryIndex.map { element.children[$0].plainText } ?? "Details"
                let children = element.children.enumerated().compactMap { index, node in
                    index == summaryIndex ? nil : node
                }
                content = .details(title: summary, initiallyOpen: element.isOpen, blocks: blocks(children, path: path + [0]))
            case "ol", "ul":
                let items = element.children.enumerated().map { index, child in
                    PreparedGlossaryListItem(id: id(path + [index], suffix: "item"), blocks: blocks([child], path: path + [index]))
                }
                content = .list(ordered: element.tag == "ol", items: items)
            case "ruby":
                let reading = element.children.compactMap { node -> String? in
                    if case .element(let child) = node, child.tag == "rt" { return node.plainText }
                    return nil
                }.joined()
                let base = element.children.compactMap { node -> String? in
                    if case .element(let child) = node, ["rt", "rp"].contains(child.tag) { return nil }
                    return node.plainText
                }.joined()
                content = .ruby(base: base, reading: reading)
            case "table":
                content = .table(tableRows(element.children, path: path + [0]))
            default:
                if let text = inlineText(node) {
                    content = .inline([.init(id: id(path, suffix: "run"), content: .text(text))])
                } else {
                    content = .container(blocks(element.children, path: path + [0]))
                }
            }
            return .init(id: id(path, suffix: element.tag), content: content, style: element.style, title: element.title)
        }
    }

    private static func inlineText(_ node: GlossaryNode) -> AttributedString? {
        switch node {
        case .text(let value): return AttributedString(value)
        case .lineBreak: return AttributedString("\n")
        case .image: return nil
        case .element(let element):
            guard !["div", "ol", "ul", "li", "table", "ruby", "details"].contains(element.tag) else { return nil }
            var result = AttributedString()
            for child in element.children {
                guard let value = inlineText(child) else { return nil }
                result += value
            }
            if element.style.bold { result.font = .body.bold() }
            if element.style.italic { result.inlinePresentationIntent = (result.inlinePresentationIntent ?? []).union(.emphasized) }
            if element.style.underline { result.underlineStyle = .single }
            if element.style.strikethrough { result.strikethroughStyle = .single }
            if let color = safeColor(element.style.color) { result.foregroundColor = color }
            return result
        }
    }

    private static func tableRows(_ nodes: [GlossaryNode], path: [Int]) -> [PreparedGlossaryTableRow] {
        nodes.enumerated().flatMap { index, node in
            guard case .element(let element) = node else { return [PreparedGlossaryTableRow]() }
            let rowPath = path + [index]
            guard element.tag == "tr" else { return tableRows(element.children, path: rowPath) }
            let cells = element.children.enumerated().map { cellIndex, cell in
                PreparedGlossaryTableCell(
                    id: id(rowPath + [cellIndex], suffix: "cell"),
                    blocks: [block(cell, path: rowPath + [cellIndex])],
                    columnSpan: columnSpan(cell)
                )
            }
            return [.init(id: id(rowPath, suffix: "row"), cells: cells)]
        }
    }

    private static func columnSpan(_ node: GlossaryNode) -> Int {
        if case .element(let element) = node { return element.columnSpan }
        return 1
    }

    private static func id(_ path: [Int], suffix: String) -> String {
        path.map(String.init).joined(separator: ".") + ":" + suffix
    }
}

struct GlossaryView: View {
    let glossary: PreparedGlossary
    let bundleURL: URL?

    init(nodes: [GlossaryNode], bundleURL: URL?) {
        glossary = PreparedGlossary(nodes: nodes)
        self.bundleURL = bundleURL
    }

    init(glossary: PreparedGlossary, bundleURL: URL?) {
        self.glossary = glossary
        self.bundleURL = bundleURL
    }

    var body: some View {
        GlossaryBlocksView(blocks: glossary.blocks, bundleURL: bundleURL)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}

private struct GlossaryBlocksView: View {
    let blocks: [PreparedGlossaryBlock]
    let bundleURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(blocks) { block in
                GlossaryBlockView(block: block, bundleURL: bundleURL)
            }
        }
    }
}

private struct GlossaryBlockView: View {
    let block: PreparedGlossaryBlock
    let bundleURL: URL?

    var body: some View {
        content
            .glossaryStyle(block.style, title: block.title)
    }

    @ViewBuilder private var content: some View {
        switch block.content {
        case .inline(let runs):
            InlineGlossaryLayout(spacing: 2) {
                ForEach(runs) { run in
                    GlossaryInlineRunView(run: run, bundleURL: bundleURL)
                }
            }
        case .image(let reference):
            DictionaryImageView(reference: reference, bundleURL: bundleURL)
        case .container(let blocks):
            GlossaryBlocksView(blocks: blocks, bundleURL: bundleURL)
        case .details(let title, let initiallyOpen, let blocks):
            GlossaryDisclosure(title: title, initiallyOpen: initiallyOpen) {
                GlossaryBlocksView(blocks: blocks, bundleURL: bundleURL)
            }
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text(ordered ? "\(index + 1)." : "•").foregroundStyle(.secondary)
                        GlossaryBlocksView(blocks: item.blocks, bundleURL: bundleURL)
                    }
                }
            }
        case .ruby(let base, let reading):
            VStack(spacing: 0) {
                Text(reading).font(.caption2)
                Text(base)
            }
            .accessibilityLabel("\(base), \(reading)")
        case .table(let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                    ForEach(rows) { row in
                        GridRow(alignment: .top) {
                            ForEach(row.cells) { cell in
                                GlossaryBlocksView(blocks: cell.blocks, bundleURL: bundleURL)
                                    .padding(3)
                                    .gridCellColumns(cell.columnSpan)
                            }
                        }
                    }
                }
            }
        }
    }

}

private struct GlossaryInlineRunView: View {
    let run: PreparedGlossaryInlineRun
    let bundleURL: URL?

    @ViewBuilder var body: some View {
        switch run.content {
        case .text(let text):
            Text(text)
        case .image(let reference):
            DictionaryImageView(reference: reference, bundleURL: bundleURL)
        }
    }
}

private struct InlineGlossaryLayout: Layout {
    let spacing: CGFloat

    struct Cache {
        var width: CGFloat?
        var subviewCount = 0
        var measurement: Measurement?
    }

    struct Measurement {
        let size: CGSize
        let points: [CGPoint]
        let sizes: [CGSize]
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(subviewCount: subviews.count)
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = Cache(subviewCount: subviews.count)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        measurement(width: resolvedWidth(proposal.width), subviews: subviews, cache: &cache).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let measured = measurement(width: resolvedWidth(bounds.width), subviews: subviews, cache: &cache)
        for index in subviews.indices {
            subviews[index].place(
                at: .init(x: bounds.minX + measured.points[index].x, y: bounds.minY + measured.points[index].y),
                anchor: .topLeading,
                proposal: .init(measured.sizes[index])
            )
        }
    }

    private func measurement(width: CGFloat, subviews: Subviews, cache: inout Cache) -> Measurement {
        if cache.width == width, cache.subviewCount == subviews.count, let measurement = cache.measurement {
            return measurement
        }
        var points: [CGPoint] = []
        var sizes: [CGSize] = []
        points.reserveCapacity(subviews.count)
        sizes.reserveCapacity(subviews.count)
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            var available = max(1, width - x)
            let ideal = subview.sizeThatFits(.unspecified)
            if x > 0, ideal.width > available {
                x = 0; y += lineHeight + spacing; lineHeight = 0; available = width
            }
            let size = ideal.width <= available ? ideal : subview.sizeThatFits(.init(width: available, height: nil))
            points.append(.init(x: x, y: y)); sizes.append(size)
            x += size.width + spacing; lineHeight = max(lineHeight, size.height)
        }
        let measurement = Measurement(size: .init(width: width, height: y + lineHeight), points: points, sizes: sizes)
        cache.width = width
        cache.subviewCount = subviews.count
        cache.measurement = measurement
        return measurement
    }

    private func resolvedWidth(_ width: CGFloat?) -> CGFloat {
        max(1, width ?? 430)
    }
}

struct GlossaryDisclosure<Content: View>: View {
    let title: String
    @State private var expanded: Bool
    let content: () -> Content

    init(title: String, initiallyOpen: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        _expanded = State(initialValue: initiallyOpen)
        self.content = content
    }
    var body: some View { DisclosureGroup(title, isExpanded: $expanded, content: content) }
}

private func safeColor(_ source: String?) -> Color? {
    guard let source else { return nil }
    switch source.lowercased() {
    case "red": return .red
    case "blue": return .blue
    case "green": return .green
    case "gray", "grey": return .secondary
    case "orange": return .orange
    case "purple": return .purple
    default:
        guard source.hasPrefix("#"), source.count == 7, let value = UInt32(source.dropFirst(), radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

private extension View {
    @ViewBuilder
    func glossaryStyle(_ style: GlossaryStyle?, title: String) -> some View {
        if let style {
            self
                .fontWeight(style.bold ? .bold : .regular)
                .italic(style.italic)
                .foregroundStyle(safeColor(style.color) ?? .primary)
                .background(safeColor(style.backgroundColor) ?? .clear)
                .frame(
                    maxWidth: .infinity,
                    alignment: style.alignment == "center" ? .center : style.alignment == "right" ? .trailing : .leading
                )
                .help(title)
        } else {
            self
        }
    }
}

struct EntryMetadataView: View {
    let content: DictionaryContent
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let tags = content.details.metadata.termTags + content.details.metadata.definitionTags.filter { tag in
                !content.details.metadata.termTags.contains { $0.name == tag.name }
            }
            if !tags.isEmpty {
                Text(tags.map(\.name).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                    .help(tags.map { "\($0.name): \($0.notes)" }.joined(separator: "\n"))
            }
            ForEach(Array(content.sources.enumerated()), id: \.offset) { _, source in
                Text(source.title).font(.caption2).foregroundStyle(.tertiary)
                if !source.metadata.frequencies.isEmpty {
                    Text("Frequency: \(source.metadata.frequencies.map(\.displayValue).joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(source.metadata.pitches.enumerated()), id: \.offset) { _, pitch in
                    PitchAccentView(pitch: pitch).help(source.title)
                }
            }
        }
    }
}

struct PitchAccentView: View {
    let pitch: DictionaryPitchAccent
    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            let highs = pitch.highPitch
            ForEach(Array((pitch.morae + ["○"]).enumerated()), id: \.offset) { index, mora in
                VStack(spacing: 2) {
                    Rectangle().frame(width: 15, height: 2).offset(y: highs[index] ? -3 : 3)
                    Text(mora).font(.caption)
                        .foregroundStyle(pitch.devoicingPositions.contains(index + 1) ? .secondary : .primary)
                        .overlay(alignment: .topTrailing) {
                            if pitch.nasalPositions.contains(index + 1) {
                                Circle().stroke(lineWidth: 1).frame(width: 4, height: 4).offset(x: 3, y: -2)
                            }
                        }
                }
            }
            Text("[\(pitch.position)]").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(pitch.reading), pitch accent \(pitch.position)")
    }
}
