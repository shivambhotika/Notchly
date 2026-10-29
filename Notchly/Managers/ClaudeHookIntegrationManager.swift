//
//  ClaudeHookIntegrationManager.swift
//  Notchly
//
//  Created by n0xbyte on 25.03.2026.
//

import Foundation
import Combine

@MainActor
final class ClaudeHookIntegrationManager: ObservableObject {
    @Published private(set) var installState: AgentHookInstallState = .unknown

    private let fileManager = FileManager.default

    var isInstalled: Bool {
        if case .installed = installState {
            return true
        }
        return false
    }

    var configPreview: String {
        """
        {
          "hooks": {
            "PermissionRequest": [{
              "hooks": [{ "type": "command", "command": "\(jsonPreviewCommand(approvalHookCommand))" }]
            }],
            "Notification": [{
              "matcher": "permission_prompt",
              "hooks": [{ "type": "command", "command": "\(jsonPreviewCommand(approvalHookCommand))" }]
            }, {
              "matcher": "idle_prompt",
              "hooks": [{ "type": "command", "command": "\(jsonPreviewCommand(waitingHookCommand))" }]
            }],
            "Stop": [{
              "hooks": [{ "type": "command", "command": "\(jsonPreviewCommand(completedHookCommand))" }]
            }],
            "StopFailure": [{
              "hooks": [{ "type": "command", "command": "\(jsonPreviewCommand(failedHookCommand))" }]
            }],
            "PreToolUse": [{
              "hooks": [{ "type": "command", "command": "\(jsonPreviewCommand(approvedHookCommand))" }]
            }],
            "PostToolUse": [{
              "hooks": [{ "type": "command", "command": "\(jsonPreviewCommand(approvedHookCommand))" }]
            }],
            "UserPromptSubmit": [{
              "hooks": [{ "type": "command", "command": "\(jsonPreviewCommand(approvedHookCommand))" }]
            }],
            "SessionEnd": [{
              "hooks": [{ "type": "command", "command": "\(jsonPreviewCommand(approvedHookCommand))" }]
            }]
          }
        }
        """
    }

    func refreshStatus() {
        let installed = isHookInstalled()
        if installed {
            upgradeHookScriptIfNeeded()
        }
        installState = installed ? .installed : .notInstalled
    }

    /// Existing installs keep their settings.json entries; only the script body changes,
    /// so an older one-way script is swapped for the two-way bridge in place.
    private func upgradeHookScriptIfNeeded() {
        let current = try? String(contentsOf: hookScriptURL, encoding: .utf8)
        guard current != hookScript else { return }
        try? installHookScript()
    }

    func install() {
        installState = .installing

        do {
            try installHookScript()
            try updateClaudeConfig()
            refreshStatus()
        } catch {
            installState = .failed(error.localizedDescription)
        }
    }

    private func installHookScript() throws {
        try fileManager.createDirectory(
            at: hookDirectoryURL,
            withIntermediateDirectories: true
        )

        try hookScript.write(to: hookScriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: hookScriptURL.path
        )
    }

    private func updateClaudeConfig() throws {
        try fileManager.createDirectory(
            at: claudeConfigDirectoryURL,
            withIntermediateDirectories: true
        )

        var config = try loadConfig()
        var hooks = try hooksObject(from: config)
        hooks = try removingManagedHandlers(from: hooks)

        // Held open while the notch shows Allow/Deny; the app releases it after ~90s.
        try appendHandler(
            eventName: "PermissionRequest",
            command: approvalHookCommand,
            timeout: Self.permissionHookTimeout,
            to: &hooks
        )
        try appendHandler(
            eventName: "Notification",
            matcher: "permission_prompt",
            command: approvalHookCommand,
            to: &hooks
        )
        try appendHandler(
            eventName: "Notification",
            matcher: "idle_prompt",
            command: waitingHookCommand,
            to: &hooks
        )
        try appendHandler(eventName: "Stop", command: completedHookCommand, to: &hooks)
        try appendHandler(eventName: "StopFailure", command: failedHookCommand, to: &hooks)
        try appendHandler(eventName: "PreToolUse", command: approvedHookCommand, to: &hooks)
        try appendHandler(eventName: "PostToolUse", command: approvedHookCommand, to: &hooks)
        try appendHandler(eventName: "PermissionDenied", command: approvedHookCommand, to: &hooks)
        try appendHandler(eventName: "UserPromptSubmit", command: approvedHookCommand, to: &hooks)
        try appendHandler(eventName: "SessionEnd", command: approvedHookCommand, to: &hooks)

        config["hooks"] = hooks
        let data = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: claudeConfigURL, options: .atomic)
    }

    private func loadConfig() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: claudeConfigURL.path) else {
            return [:]
        }

        let data = try Data(contentsOf: claudeConfigURL)
        guard !data.isEmpty else { return [:] }

        let object = try JSONSerialization.jsonObject(with: data)
        guard let config = object as? [String: Any] else {
            throw ClaudeHookIntegrationError.invalidRootObject
        }
        return config
    }

    private func hooksObject(from config: [String: Any]) throws -> [String: Any] {
        guard let existingHooks = config["hooks"] else { return [:] }
        guard let hooks = existingHooks as? [String: Any] else {
            throw ClaudeHookIntegrationError.invalidHooksObject
        }
        return hooks
    }

    private func removingManagedHandlers(from hooks: [String: Any]) throws -> [String: Any] {
        var updatedHooks = hooks

        for (eventName, value) in hooks {
            guard let groups = value as? [[String: Any]] else {
                throw ClaudeHookIntegrationError.invalidEvent(eventName)
            }

            let keptGroups = groups.compactMap { group -> [String: Any]? in
                guard let handlers = group["hooks"] as? [[String: Any]] else {
                    return group
                }

                let keptHandlers = handlers.filter { handler in
                    guard let command = handler["command"] as? String else { return true }
                    return !command.contains(hookScriptURL.path)
                }

                guard !keptHandlers.isEmpty else { return nil }
                var updatedGroup = group
                updatedGroup["hooks"] = keptHandlers
                return updatedGroup
            }

            updatedHooks[eventName] = keptGroups
        }

        return updatedHooks
    }

    private func appendHandler(
        eventName: String,
        matcher: String? = nil,
        command: String,
        timeout: Int? = nil,
        to hooks: inout [String: Any]
    ) throws {
        var groups: [[String: Any]] = []
        if let existingGroups = hooks[eventName] {
            guard let parsedGroups = existingGroups as? [[String: Any]] else {
                throw ClaudeHookIntegrationError.invalidEvent(eventName)
            }
            groups = parsedGroups
        }

        var handler: [String: Any] = [
            "type": "command",
            "command": command
        ]
        if let timeout {
            handler["timeout"] = timeout
        }
        var group: [String: Any] = [
            "hooks": [handler]
        ]
        if let matcher {
            group["matcher"] = matcher
        }

        groups.append(group)
        hooks[eventName] = groups
    }

    private func isHookInstalled() -> Bool {
        guard fileManager.isExecutableFile(atPath: hookScriptURL.path),
              let data = try? Data(contentsOf: claudeConfigURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let config = object as? [String: Any],
              let hooks = config["hooks"] as? [String: Any] else {
            return false
        }

        return containsHandler(in: hooks, eventName: "PermissionRequest", command: approvalHookCommand) &&
            containsHandler(in: hooks, eventName: "Notification", matcher: "permission_prompt", command: approvalHookCommand) &&
            containsHandler(in: hooks, eventName: "Notification", matcher: "idle_prompt", command: waitingHookCommand) &&
            containsHandler(in: hooks, eventName: "Stop", command: completedHookCommand) &&
            containsHandler(in: hooks, eventName: "StopFailure", command: failedHookCommand) &&
            containsHandler(in: hooks, eventName: "PreToolUse", command: approvedHookCommand) &&
            containsHandler(in: hooks, eventName: "PostToolUse", command: approvedHookCommand) &&
            containsHandler(in: hooks, eventName: "PermissionDenied", command: approvedHookCommand) &&
            containsHandler(in: hooks, eventName: "UserPromptSubmit", command: approvedHookCommand) &&
            containsHandler(in: hooks, eventName: "SessionEnd", command: approvedHookCommand)
    }

    private func containsHandler(
        in hooks: [String: Any],
        eventName: String,
        matcher: String? = nil,
        command: String
    ) -> Bool {
        guard let groups = hooks[eventName] as? [[String: Any]] else { return false }

        return groups.contains { group in
            if let matcher, group["matcher"] as? String != matcher {
                return false
            }

            guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
            return handlers.contains { handler in
                handler["type"] as? String == "command" && handler["command"] as? String == command
            }
        }
    }

    private var completedHookCommand: String {
        "\"\(hookScriptURL.path)\" completed"
    }

    private var failedHookCommand: String {
        "\"\(hookScriptURL.path)\" failed"
    }

    private var approvalHookCommand: String {
        "\"\(hookScriptURL.path)\" approval"
    }

    private var waitingHookCommand: String {
        "\"\(hookScriptURL.path)\" waiting"
    }

    private var approvedHookCommand: String {
        "\"\(hookScriptURL.path)\" approved"
    }

    private func jsonPreviewCommand(_ command: String) -> String {
        command.replacingOccurrences(of: "\"", with: "\\\"")
    }

    static let permissionHookTimeout = 120

    private var hookScript: String {
        """
#!/bin/sh
# notchly-claude-hook v2 (two-way notch bridge)
# Sends the raw Claude Code hook payload to Notchly over a private Unix socket.
# For PermissionRequest, Notchly may reply with an allow/deny decision; empty
# output means "no decision" and Claude Code shows its normal prompt.

event_type="${1:-completed}"
support_dir="$HOME/Library/Application Support/Notchly"
socket_path="$support_dir/agent.sock"

if [ -S "$socket_path" ] && [ -x /usr/bin/nc ]; then
  {
    printf '{"v":2,"source":"claude","kind":"%s"}\\n' "$event_type"
    cat
    printf '\\n\\036\\n'
  } | /usr/bin/nc -U "$socket_path" 2>/dev/null
  exit 0
fi

cat >/dev/null

# Notchly not running (or no nc): keep the old one-way alert file working.
mkdir -p "$support_dir"
case "$event_type" in
  completed|stop) type="completed"; title="Task completed" ;;
  failed|stop_failure) type="failed"; title="Task failed" ;;
  approval|notification|permission_prompt) type="access_request"; title="Need approval" ;;
  waiting|idle_prompt) type="waiting"; title="Waiting for input" ;;
  *) type="clear"; title="" ;;
esac
printf '{"source":"claude","type":"%s","title":"%s","ttl":3}\\n' "$type" "$title" >> "$support_dir/agent-events.jsonl"
exit 0
"""
    }

    private var claudeConfigDirectoryURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    private var claudeConfigURL: URL {
        claudeConfigDirectoryURL.appendingPathComponent("settings.json")
    }

    private var hookDirectoryURL: URL {
        fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notchly", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }

    private var hookScriptURL: URL {
        hookDirectoryURL.appendingPathComponent("notchly-claude-hook")
    }
}

private enum ClaudeHookIntegrationError: LocalizedError {
    case invalidRootObject
    case invalidHooksObject
    case invalidEvent(String)

    var errorDescription: String? {
        switch self {
        case .invalidRootObject:
            return "Claude settings must contain a JSON object."
        case .invalidHooksObject:
            return "The hooks value in Claude settings must be a JSON object."
        case .invalidEvent(let eventName):
            return "The Claude hook event \(eventName) must contain an array."
        }
    }
}
