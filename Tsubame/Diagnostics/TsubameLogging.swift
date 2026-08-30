import Foundation
import OSLog

enum TsubameLogging {
    static let subsystem = "com.krnya.Tsubame"

    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    static let permission = Logger(subsystem: subsystem, category: "permission")
    static let dictionaryLibrary = Logger(subsystem: subsystem, category: "dictionary.library")
    static let anki = Logger(subsystem: subsystem, category: "anki")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let capture = Logger(subsystem: subsystem, category: "capture.ax")
    static let lookup = Logger(subsystem: subsystem, category: "lookup")
    static let popup = Logger(subsystem: subsystem, category: "popup")
    static let performance = Logger(subsystem: subsystem, category: "performance")
    static let signposter = OSSignposter(logger: performance)

    static func logCapturedText(_ text: String, requestID: UInt64) {
#if DEBUG
        if ProcessInfo.processInfo.environment["TSUBAME_LOG_CAPTURE_TEXT"] == "1" {
            capture.debug(
                "request=\(requestID, privacy: .public) selectedText=\(text, privacy: .public)"
            )
        }
#endif
    }
}

extension Duration {
    var milliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1_000
            + Double(parts.attoseconds) / 1_000_000_000_000_000
    }
}

struct PipelineTimings: Sendable, Equatable {
    let capture: Duration
    let lookup: Duration
    let present: Duration
    let total: Duration

    var debugSummary: String {
        "Capture \(capture.milliseconds.formattedMilliseconds) ms · "
            + "Lookup \(lookup.milliseconds.formattedMilliseconds) ms · "
            + "Present \(present.milliseconds.formattedMilliseconds) ms · "
            + "Total \(total.milliseconds.formattedMilliseconds) ms"
    }
}

private extension Double {
    var formattedMilliseconds: String {
        formatted(.number.precision(.fractionLength(2)))
    }
}
