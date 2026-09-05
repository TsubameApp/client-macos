import AppKit
import SwiftUI
import TsubameCore

struct GlossaryView: View {
    let nodes: [GlossaryNode]
    let bundleURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                block
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Adjacent text/span nodes form one paragraph, not one vertical row each.
    private var blocks: [AnyView] {
        var result: [AnyView] = []
        var run: [AnyView] = []
        var text = AttributedString()
        func flushText() {
            if !text.characters.isEmpty { run.append(AnyView(Text(text).textSelection(.enabled))); text = AttributedString() }
        }
        func flush() {
            flushText()
            if !run.isEmpty {
                let views = run
                result.append(AnyView(InlineGlossaryLayout(spacing: 2) {
                    ForEach(Array(views.enumerated()), id: \.offset) { _, view in view }
                }))
                run = []
            }
        }
        for node in nodes {
            if let value = inlineText(node) { text += value }
            else if case .image(let image) = node, image.sizeUnits == "em", (image.height ?? 99) <= 3 {
                flushText(); run.append(nodeView(node))
            }
            else { flush(); result.append(nodeView(node)) }
        }
        flush()
        return result
    }

    private func nodeView(_ node: GlossaryNode) -> AnyView {
        switch node {
        case .text(let text): return AnyView(Text(text).textSelection(.enabled))
        case .lineBreak: return AnyView(Text(" ").font(.caption))
        case .image(let reference): return AnyView(DictionaryImageView(reference: reference, bundleURL: bundleURL))
        case .element(let element):
            let content: AnyView
            switch element.tag {
            case "details":
                let summary = element.children.first { if case .element(let child) = $0 { return child.tag == "summary" }; return false }
                let children = element.children.filter { if case .element(let child) = $0 { return child.tag != "summary" }; return true }
                content = AnyView(GlossaryDisclosure(title: summary?.plainText ?? "Details", initiallyOpen: element.isOpen) {
                    GlossaryView(nodes: children, bundleURL: bundleURL)
                })
            case "ol", "ul":
                content = AnyView(VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(element.children.enumerated()), id: \.offset) { index, child in
                        HStack(alignment: .top, spacing: 6) {
                            Text(element.tag == "ol" ? "\(index + 1)." : "•").foregroundStyle(.secondary)
                            GlossaryView(nodes: [child], bundleURL: bundleURL)
                        }
                    }
                })
            case "ruby":
                let reading = element.children.filter { if case .element(let child) = $0 { return child.tag == "rt" }; return false }.map(\.plainText).joined()
                let base = element.children.filter { if case .element(let child) = $0 { return !["rt", "rp"].contains(child.tag) }; return true }.map(\.plainText).joined()
                content = AnyView(VStack(spacing: 0) { Text(reading).font(.caption2); Text(base) }.accessibilityLabel("\(base), \(reading)"))
            case "table":
                let rows = tableRows(element.children)
                content = AnyView(ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                            GridRow(alignment: .top) {
                                ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                                    nodeView(cell).padding(3).gridCellColumns(columnSpan(cell))
                                }
                            }
                        }
                    }
                })
            default:
                if let text = inlineText(node) {
                    content = AnyView(Text(text).textSelection(.enabled))
                } else {
                    content = AnyView(GlossaryView(nodes: element.children, bundleURL: bundleURL))
                }
            }
            return AnyView(content
                .fontWeight(element.style.bold ? .bold : .regular)
                .italic(element.style.italic)
                .foregroundStyle(safeColor(element.style.color) ?? .primary)
                .background(safeColor(element.style.backgroundColor) ?? .clear)
                .frame(maxWidth: .infinity, alignment: element.style.alignment == "center" ? .center : element.style.alignment == "right" ? .trailing : .leading)
                .help(element.title))
        }
    }

    private func inlineText(_ node: GlossaryNode) -> AttributedString? {
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

    private func tableRows(_ nodes: [GlossaryNode]) -> [[GlossaryNode]] {
        nodes.flatMap { node in
            guard case .element(let element) = node else { return [[GlossaryNode]]() }
            return element.tag == "tr" ? [element.children] : tableRows(element.children)
        }
    }

    private func columnSpan(_ node: GlossaryNode) -> Int {
        if case .element(let element) = node { return element.columnSpan }
        return 1
    }
}

private struct InlineGlossaryLayout: Layout {
    let spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        dimensions(proposal: proposal, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measured = dimensions(proposal: .init(width: bounds.width, height: proposal.height), subviews: subviews)
        for (subview, point) in zip(subviews, measured.points) {
            subview.place(at: .init(x: bounds.minX + point.x, y: bounds.minY + point.y), anchor: .topLeading,
                          proposal: .init(width: measured.sizes[point.index].width, height: measured.sizes[point.index].height))
        }
    }
    private func dimensions(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [(x: CGFloat, y: CGFloat, index: Int)], sizes: [CGSize]) {
        let width = max(1, proposal.width ?? 430)
        var points: [(CGFloat, CGFloat, Int)] = [], sizes: [CGSize] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            var available = max(1, width - x)
            let ideal = subview.sizeThatFits(.unspecified)
            if x > 0, ideal.width > available {
                x = 0; y += lineHeight + spacing; lineHeight = 0; available = width
            }
            let size = subview.sizeThatFits(.init(width: min(ideal.width, available), height: proposal.height))
            points.append((x, y, index)); sizes.append(size)
            x += size.width + spacing; lineHeight = max(lineHeight, size.height)
        }
        return (.init(width: width, height: y + lineHeight), points, sizes)
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
