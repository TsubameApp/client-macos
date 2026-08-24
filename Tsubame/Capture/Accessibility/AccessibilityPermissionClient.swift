@preconcurrency import ApplicationServices
import AppKit
import Foundation
import OSLog

enum AccessibilityPermissionStatus: String, Sendable, Equatable {
    case granted
    case denied
}

struct AccessibilityPermissionClient: Sendable {
    func status() -> AccessibilityPermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }

    @MainActor
    func requestAndOpenSystemSettings() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        TsubameLogging.permission.notice(
            "Accessibility permission requested currentStatus=\(trusted, privacy: .public)"
        )

        guard let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            TsubameLogging.permission.error("Could not create Accessibility settings URL")
            return
        }

        let opened = NSWorkspace.shared.open(settingsURL)
        if opened {
            TsubameLogging.permission.notice("Opened Accessibility system settings")
        } else {
            TsubameLogging.permission.error("Could not open Accessibility system settings")
        }
    }
}
