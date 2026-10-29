//
//  TerminalAgentHookIntegrationManager.swift
//  Notchly
//
//  One-way jsonl hooks for terminal CLIs (Grok, T3, AutoRouter, etc.).
//

import Foundation
import Combine

struct TerminalAgentDefinition: Identifiable {
    let id: String
    let title: String
    let subtitle: String
}

@MainActor
final class TerminalAgentHookIntegrationManager: ObservableObject {
    @Published private(set) var installState: [String: AgentHookInstallState] = [:]

    let agents: [TerminalAgentDefinition] = [
        TerminalAgentDefinition(id: "grok", title: "Grok CLI", subtitle: "Terminal agent alerts"),
        TerminalAgentDefinition(id: "t3", title: "T3 Code", subtitle: "Terminal agent alerts"),
        TerminalAgentDefinition(id: "autorouter", title: "AutoRouter", subtitle: "Terminal agent alerts"),
    ]

    private let fileManager = FileManager.default

    func refreshStatus() {
        var next: [String: AgentHookInstallState] = [:]
        for agent in agents {
            next[agent.id] = isInstalled(agent.id) ? .installed : .notInstalled
        }
        installState = next
    }

    func install(agentID: String) {
        installState[agentID] = .installing
        do {
            try installSharedHookScriptIfNeeded()
            try installWrapper(for: agentID)
            refreshStatus()
        } catch {
            installState[agentID] = .failed(error.localizedDescription)
        }
    }

    func wrapperPath(for agentID: String) -> String {
        hookDirectoryURL.appendingPathComponent("notchly-\(agentID)-hook").path
    }

    private func isInstalled(_ agentID: String) -> Bool {
        fileManager.isExecutableFile(atPath: wrapperPath(for: agentID))
    }

    private func installSharedHookScriptIfNeeded() throws {
        try fileManager.createDirectory(at: hookDirectoryURL, withIntermediateDirectories: true)
        let shared = hookDirectoryURL.appendingPathComponent("notchly-terminal-hook")
        guard !fileManager.isExecutableFile(atPath: shared.path) else { return }
        try sharedHookScript.write(to: shared, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shared.path)
    }

    private func installWrapper(for agentID: String) throws {
        let url = URL(fileURLWithPath: wrapperPath(for: agentID))
        let script = """
        #!/bin/sh
        exec "\(hookDirectoryURL.appendingPathComponent("notchly-terminal-hook").path)" "\(agentID)" "$@"
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private var sharedHookScript: String {
        """
        #!/bin/sh
        set -eu
        source="${1:-unknown}"
        shift || true
        kind="${1:-progress}"
        title="${2:-Working}"
        message="${3:-}"
        ttl="${4:-120}"
        events_dir="$HOME/Library/Application Support/Notchly"
        events_file="$events_dir/agent-events.jsonl"
        mkdir -p "$events_dir"
        case "$kind" in
          clear|done|stop) type="clear"; title=""; message=""; ttl=3 ;;
          fail|failed) type="failed"; title="Task failed"; ttl=3 ;;
          approve|approval) type="access_request"; title="Need approval"; ttl=120 ;;
          wait|waiting) type="waiting"; title="Waiting for input"; ttl=120 ;;
          *) type="progress"; ttl="$ttl" ;;
        esac
        printf '{"source":"%s","type":"%s","title":"%s","message":"%s","ttl":%s}\\n' "$source" "$type" "$title" "$message" "$ttl" >> "$events_file"
        """
    }

    private var hookDirectoryURL: URL {
        fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notchly", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }
}
