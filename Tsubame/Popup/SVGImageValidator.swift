import Foundation

/// Rebuild an inert SVG instead of trusting the original XML/CSS. Editor
/// metadata is dropped; simple presentation CSS is retained. No web renderer.
final class SVGImageValidator: NSObject, XMLParserDelegate {
    private var output = ""
    private var elements = 0
    private var depth = 0
    private var skipped = 0
    private var styleText: String?
    private var reason: String?
    private static let elements: Set<String> = ["svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "defs", "linearGradient", "radialGradient", "stop", "clipPath", "mask", "use", "title", "desc", "text", "tspan", "symbol", "style"]
    private static let properties: Set<String> = ["fill", "fill-opacity", "fill-rule", "stroke", "stroke-width", "stroke-opacity", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset", "opacity", "color", "font-size", "font-family", "font-weight", "font-style", "text-anchor", "dominant-baseline", "letter-spacing", "word-spacing", "display", "visibility", "clip-path", "stop-color", "stop-opacity", "paint-order", "enable-background", "shape-rendering", "text-rendering"]
    private static let attributes: Set<String> = ["id", "class", "xmlns", "xmlns:xlink", "version", "viewBox", "preserveAspectRatio", "x", "y", "x1", "x2", "y1", "y2", "dx", "dy", "width", "height", "cx", "cy", "r", "rx", "ry", "d", "points", "transform", "offset", "gradientUnits", "gradientTransform", "spreadMethod", "fx", "fy", "clipPathUnits", "maskUnits", "maskContentUnits", "href", "xlink:href", "xml:space", "style", "type"]

    static func validate(_ data: Data) -> Bool { (try? sanitized(data)) != nil }

    static func sanitized(_ data: Data) throws -> Data {
        guard data.count <= 2 * 1_024 * 1_024 else { throw DictionaryImageError.unsafeSVG("file too large") }
        let lower = String(decoding: data, as: UTF8.self).lowercased()
        guard !lower.contains("<!doctype"), !lower.contains("<!entity"), !lower.contains("<?xml-stylesheet") else {
            throw DictionaryImageError.unsafeSVG("entities or external stylesheet")
        }
        let delegate = SVGImageValidator()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.reason == nil, delegate.elements > 0 else {
            throw DictionaryImageError.unsafeSVG(delegate.reason ?? "invalid XML")
        }
        return Data(delegate.output.utf8)
    }

    private func reject(_ parser: XMLParser, _ reason: String) { self.reason = reason; parser.abortParsing() }
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    private static func safeValue(_ value: String) -> Bool {
        let lower = value.lowercased()
        guard !lower.contains("\\"), !lower.contains("/*"), !lower.contains("@"), !lower.contains("expression("),
              !lower.contains("javascript:"), !lower.contains("data:"), !lower.contains("://") else { return false }
        // Paint servers may only reference an identifier in this same SVG.
        let stripped = lower.replacingOccurrences(of: "url\\(\\s*#[a-z0-9_.:-]+\\s*\\)", with: "", options: .regularExpression)
        return !stripped.contains("url")
    }
    private static func declarations(_ source: String) -> String? {
        guard safeValue(source) else { return nil }
        var result: [String] = []
        for part in source.split(separator: ";") {
            let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard pair.count == 2 else { continue }
            if properties.contains(pair[0].lowercased()) { result.append("\(pair[0]):\(pair[1])") }
        }
        return result.joined(separator: ";")
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes attrs: [String: String]) {
        elements += 1; depth += 1
        guard elements <= 10_000, depth <= 64 else { reject(parser, "element limit"); return }
        if skipped > 0 { skipped += 1; return }
        if name == "metadata" || name.hasPrefix("sodipodi:") || name.hasPrefix("inkscape:") { skipped = 1; return }
        guard (elements != 1 || name == "svg"), Self.elements.contains(name) else { reject(parser, "element \(name)"); return }
        output += "<\(name)"
        for key in attrs.keys.sorted() {
            let value = attrs[key]!
            let lower = key.lowercased()
            if lower.hasPrefix("on") { reject(parser, "event handler"); return }
            if lower.hasSuffix("href"), !value.hasPrefix("#") { reject(parser, "external reference"); return }
            guard Self.attributes.contains(key) || Self.properties.contains(key) else { continue }
            // Namespace URLs describe XML syntax; they are not fetched.
            if key == "xmlns" || key == "xmlns:xlink" {
                let expected = key == "xmlns" ? "http://www.w3.org/2000/svg" : "http://www.w3.org/1999/xlink"
                guard value == expected else { reject(parser, "namespace"); return }
            } else if !Self.safeValue(value) { reject(parser, "unsafe attribute \(key)"); return }
            let sanitized = key == "style" ? Self.declarations(value) ?? "" : value
            output += " \(key)=\"\(Self.escape(sanitized))\""
        }
        output += ">"
        if name == "style" { styleText = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipped == 0 else { return }
        if styleText != nil { styleText! += string }
        else { output += Self.escape(string) }
    }
    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        self.parser(parser, foundCharacters: String(decoding: block, as: UTF8.self))
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        depth -= 1
        if skipped > 0 { skipped -= 1; return }
        if name == "style", let css = styleText {
            guard Self.safeValue(css) else { reject(parser, "unsafe stylesheet"); return }
            let chunks = css.split(separator: "}")
            for chunk in chunks where !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let parts = chunk.split(separator: "{", maxSplits: 1)
                guard parts.count == 2 else { reject(parser, "stylesheet syntax"); return }
                let selector = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                guard selector.range(of: "^[.#]?[a-zA-Z_][a-zA-Z0-9_-]*(\\s*,\\s*[.#]?[a-zA-Z_][a-zA-Z0-9_-]*)*$", options: .regularExpression) != nil,
                      let declarations = Self.declarations(String(parts[1])) else { reject(parser, "stylesheet selector"); return }
                output += Self.escape("\(selector){\(declarations)}")
            }
            styleText = nil
        }
        output += "</\(name)>"
    }
}
