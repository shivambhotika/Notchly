//
//  AgentRelayURL.swift
//  Notchly
//

import Foundation

enum AgentRelayURL {
    static func normalizeBase(_ raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        return URL(string: "https://\(trimmed)")
    }

    static func apiPath(base: URL, path: String) -> URL {
        if #available(macOS 13.0, *) {
            return base.appending(path: path)
        }
        return base.appendingPathComponent(path)
    }
}
