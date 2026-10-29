//
//  MacVolumeController.swift
//  Notchly
//

import AppKit
import Foundation

enum MacVolumeController {
    static func outputVolume() -> Int? {
        guard let raw = runAppleScript("output volume of (get volume settings)") else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func isMuted() -> Bool? {
        guard let raw = runAppleScript("output muted of (get volume settings)")?.lowercased() else { return nil }
        return raw == "true"
    }

    static func setOutputVolume(_ level: Int) {
        let clamped = max(0, min(100, level))
        _ = runAppleScript("set volume output volume \(clamped)")
    }

    static func setMuted(_ muted: Bool) {
        _ = runAppleScript("set volume output muted \(muted ? "true" : "false")")
    }

    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let output = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return output.stringValue
    }
}
