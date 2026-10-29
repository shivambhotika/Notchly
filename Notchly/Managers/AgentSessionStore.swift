//
//  AgentSessionStore.swift
//  Notchly
//
//  Tracks live coding-agent sessions and the queue of permission requests that
//  can be answered from the notch. Feeds the existing AgentEventManager so the
//  island's presentation/animation pipeline stays the single source of UI truth.
//

import Foundation
import Combine
import AppKit

enum AgentSessionPhase: Equatable {
    case working
    case runningTool(String)
    case waitingForApproval
    case waitingForInput
    case finished
    case failed
}

struct AgentSession: Identifiable, Equatable {
    let id: String
    let source: String
    var cwd: String
    var phase: AgentSessionPhase
    var updatedAt: Date

    var projectName: String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? "session" : name
    }
}

struct AgentApprovalRequest: Identifiable, Equatable {
    let id: UUID              // bridge connection id
    let sessionID: String
    let source: String
    let projectName: String
    let toolName: String
    let summary: String
    let detail: String?
    let receivedAt: Date
    let fingerprint: String?
    let alwaysAllowPermissions: Data?

    var canAlwaysAllow: Bool { alwaysAllowPermissions != nil }

    var displayToolName: String {
        // mcp__server__tool → server · tool
        if toolName.hasPrefix("mcp__") {
            let parts = toolName.dropFirst(5).components(separatedBy: "__")
            if parts.count >= 2 { return "\(parts[0]) · \(parts.dropFirst().joined(separator: "__"))" }
        }
        return toolName
    }
}

enum AgentApprovalDecision {
    case allow
    case alwaysAllow
    case deny
    case terminal
}

@MainActor
final class AgentSessionStore: ObservableObject {
    @Published private(set) var sessions: [String: AgentSession] = [:]
    @Published private(set) var pendingApprovals: [AgentApprovalRequest] = []

    private let bridge = AgentBridgeServer()
    private let agentEventManager: AgentEventManager
    private let hotkeys = AgentApprovalHotkeys()
    private var pruneTimer: Timer?

    var currentApproval: AgentApprovalRequest? { pendingApprovals.first }
    var hasPendingApproval: Bool { !pendingApprovals.isEmpty }

    var activeSessions: [AgentSession] {
        sessions.values
            .filter { $0.phase != .finished && $0.phase != .failed }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Sessions recently touched by hooks — used for iPhone relay badges (avoids stale “Claude active”).
    var relayActiveSessions: [AgentSession] {
        let cutoff = Date().addingTimeInterval(-Self.relaySessionMaxAge)
        return sessions.values.filter { session in
            guard session.updatedAt > cutoff else { return false }
            switch session.phase {
            case .finished, .failed: return false
            case .working, .runningTool, .waitingForApproval, .waitingForInput: return true
            }
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    private static let relaySessionMaxAge: TimeInterval = 3 * 60

    init(agentEventManager: AgentEventManager) {
        self.agentEventManager = agentEventManager
    }

    func start() {
        bridge.onMessage = { [weak self] message in
            MainActor.assumeIsolated { self?.handle(message) }
        }
        bridge.onReleased = { [weak self] connectionID in
            MainActor.assumeIsolated { self?.removeApproval(connectionID, releasedExternally: true) }
        }
        hotkeys.onDecision = { [weak self] decision in
            guard let self, let request = self.currentApproval else { return }
            let effective: AgentApprovalDecision =
                (decision == .alwaysAllow && !request.canAlwaysAllow) ? .allow : decision
            self.resolve(request, effective)
        }
        bridge.start()

        pruneTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pruneStaleSessions() }
        }
    }

    func stop() {
        pruneTimer?.invalidate()
        pruneTimer = nil
        hotkeys.unregister()
        // Hand every held request back to the terminal before quitting.
        for request in pendingApprovals {
            bridge.respond(to: request.id, with: nil)
        }
        pendingApprovals.removeAll()
        bridge.stop()
    }

    // MARK: - User decisions

    func resolve(_ request: AgentApprovalRequest, _ decision: AgentApprovalDecision) {
        bridge.respond(to: request.id, with: Self.hookResponse(for: decision, request: request))
        if decision == .terminal {
            activateTerminal()
        }
        removeApproval(request.id, releasedExternally: false)
    }

    /// Applies a decision sent from the Agent Island iPhone app via the relay.
    @discardableResult
    func resolveRemoteApproval(id: UUID, decision: AgentApprovalDecision) -> Bool {
        guard let request = pendingApprovals.first(where: { $0.id == id }) else { return false }
        let effective: AgentApprovalDecision =
            (decision == .alwaysAllow && !request.canAlwaysAllow) ? .allow : decision
        resolve(request, effective)
        return true
    }

    // MARK: - Incoming hook messages

    private func handle(_ message: AgentBridgeMessage) {
        let payload = message.payload
        let source = payload.source.lowercased()
        let sessionID = payload.sessionID.isEmpty ? "\(source)-unknown" : payload.sessionID

        var session = sessions[sessionID] ?? AgentSession(
            id: sessionID,
            source: source,
            cwd: payload.cwd,
            phase: .working,
            updatedAt: Date()
        )
        if !payload.cwd.isEmpty { session.cwd = payload.cwd }
        session.updatedAt = Date()

        switch payload.hookEventName {
        case "PermissionRequest":
            session.phase = .waitingForApproval
            sessions[sessionID] = session
            enqueueApproval(message: message, session: session)
            return

        case "beforeShellExecution", "beforeMCPExecution":
            session.phase = .waitingForApproval
            sessions[sessionID] = session
            enqueueCursorExecutionApproval(message: message, session: session)
            return

        case "PreToolUse":
            session.phase = .runningTool(payload.toolName ?? "tool")

        case "PostToolUse", "PostToolUseFailure":
            session.phase = .working
            // Same call approved in the terminal: drop the now-stale notch card.
            releaseApprovals(sessionID: sessionID, matching: payload.toolInputFingerprint)

        case "UserPromptSubmit":
            session.phase = .working
            releaseApprovals(sessionID: sessionID, matching: nil)

        case "PermissionDenied":
            session.phase = .working
            releaseApprovals(sessionID: sessionID, matching: payload.toolInputFingerprint)

        case "Stop":
            session.phase = .finished
            releaseApprovals(sessionID: sessionID, matching: nil)
            sessions[sessionID] = session
            agentEventManager.publish(
                source: source,
                kind: .completed,
                title: "Done · \(session.projectName)",
                message: nil
            )
            return

        case "StopFailure":
            session.phase = .failed
            releaseApprovals(sessionID: sessionID, matching: nil)
            sessions[sessionID] = session
            agentEventManager.publish(source: source, kind: .failed, title: "Failed · \(session.projectName)")
            return

        case "SessionEnd":
            releaseApprovals(sessionID: sessionID, matching: nil)
            sessions.removeValue(forKey: sessionID)
            clearAlertIfIdle(source: source)
            return

        case "Notification":
            sessions[sessionID] = session
            handleNotification(payload, session: session)
            return

        default:
            break
        }

        sessions[sessionID] = session
        clearAlertIfIdle(source: source)
    }

    private func handleNotification(_ payload: AgentHookPayload, session: AgentSession) {
        switch payload.notificationType {
        case "idle_prompt":
            sessions[session.id]?.phase = .waitingForInput
            agentEventManager.publish(
                source: session.source,
                kind: .waiting,
                title: "Waiting · \(session.projectName)"
            )
        case "permission_prompt":
            // Only surface the passive alert if the notch is not already holding this request.
            guard !pendingApprovals.contains(where: { $0.sessionID == session.id }) else { return }
            agentEventManager.publish(
                source: session.source,
                kind: .accessRequest,
                title: "Needs approval · \(session.projectName)",
                message: payload.message
            )
        default:
            break
        }
    }

    private func enqueueApproval(message: AgentBridgeMessage, session: AgentSession) {
        let payload = message.payload
        let (summary, detail) = Self.describe(toolName: payload.toolName, input: payload.toolInput, cwd: session.cwd)

        let request = AgentApprovalRequest(
            id: message.connectionID,
            sessionID: session.id,
            source: session.source,
            projectName: session.projectName,
            toolName: payload.toolName ?? "Tool",
            summary: summary,
            detail: detail,
            receivedAt: Date(),
            fingerprint: payload.toolInputFingerprint,
            alwaysAllowPermissions: Self.alwaysAllowPermissions(from: payload.permissionSuggestionsJSON)
        )
        pendingApprovals.append(request)
        hotkeys.register()

        if pendingApprovals.count == 1 {
            presentCurrentApproval()
        }
    }

    private func enqueueCursorExecutionApproval(message: AgentBridgeMessage, session: AgentSession) {
        let payload = message.payload
        let input = payload.toolInput ?? [:]
        let command =
            (input["command"] as? String)
            ?? (input["tool_name"] as? String)
            ?? (input["server"] as? String)
            ?? payload.hookEventName
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = trimmed.count > 140 ? String(trimmed.prefix(137)) + "…" : trimmed
        let detailParts = [
            payload.hookEventName,
            session.projectName,
            payload.cwd.isEmpty ? nil : payload.cwd
        ].compactMap { $0?.isEmpty == false ? $0 : nil }
        let request = AgentApprovalRequest(
            id: message.connectionID,
            sessionID: session.id,
            source: session.source,
            projectName: session.projectName,
            toolName: payload.hookEventName,
            summary: summary.isEmpty ? "Cursor wants to run a tool" : summary,
            detail: detailParts.isEmpty ? nil : detailParts.joined(separator: " · "),
            receivedAt: Date(),
            fingerprint: payload.toolInputFingerprint,
            alwaysAllowPermissions: nil
        )
        pendingApprovals.append(request)
        hotkeys.register()
        if pendingApprovals.count == 1 {
            presentCurrentApproval()
        }
    }

    // MARK: - Queue management

    private func releaseApprovals(sessionID: String, matching fingerprint: String?) {
        let stale = pendingApprovals.filter { request in
            guard request.sessionID == sessionID else { return false }
            guard let fingerprint else { return true }
            return request.fingerprint == fingerprint
        }
        for request in stale {
            bridge.respond(to: request.id, with: nil)
            removeApproval(request.id, releasedExternally: true)
        }
    }

    private func removeApproval(_ id: UUID, releasedExternally: Bool) {
        guard let index = pendingApprovals.firstIndex(where: { $0.id == id }) else { return }
        let wasCurrent = index == 0
        let removed = pendingApprovals.remove(at: index)

        if sessions[removed.sessionID]?.phase == .waitingForApproval,
           !pendingApprovals.contains(where: { $0.sessionID == removed.sessionID }) {
            sessions[removed.sessionID]?.phase = .working
        }

        if pendingApprovals.isEmpty {
            hotkeys.unregister()
            agentEventManager.publish(source: removed.source, kind: .clear)
        } else if wasCurrent {
            presentCurrentApproval()
        }
    }

    private func presentCurrentApproval() {
        guard let request = currentApproval else { return }
        agentEventManager.publish(
            source: request.source,
            kind: .accessRequest,
            title: "Allow \(request.displayToolName)?",
            message: request.summary,
            bypassDuplicateCheck: true
        )
    }

    private func clearAlertIfIdle(source: String) {
        guard !pendingApprovals.contains(where: { $0.source == source }) else { return }
        guard let current = agentEventManager.currentEvent,
              current.source.lowercased() == source,
              current.kind == .accessRequest || current.kind == .waiting else { return }
        agentEventManager.publish(source: source, kind: .clear)
    }

    private func pruneStaleSessions() {
        let cutoff = Date().addingTimeInterval(-5 * 60)
        sessions = sessions.filter { _, session in
            session.updatedAt > cutoff || session.phase == .waitingForApproval
        }
    }

    private func activateTerminal() {
        let terminalBundleIDs = [
            "com.mitchellh.ghostty", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
            "net.kovidgoyal.kitty", "com.github.wez.wezterm", "com.apple.Terminal",
            "com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode", "dev.zed.Zed"
        ]
        let running = NSWorkspace.shared.runningApplications
        for bundleID in terminalBundleIDs {
            if let app = running.first(where: { $0.bundleIdentifier == bundleID }) {
                app.activate(options: [.activateAllWindows])
                return
            }
        }
    }

    // MARK: - Hook response encoding (Claude Code PermissionRequest contract)

    static func hookResponse(for decision: AgentApprovalDecision, request: AgentApprovalRequest) -> Data? {
        if request.source.lowercased() == "cursor",
           request.toolName == "beforeShellExecution" || request.toolName == "beforeMCPExecution" {
            switch decision {
            case .terminal:
                return nil
            case .allow, .alwaysAllow:
                return Data("{\"permission\":\"allow\"}".utf8)
            case .deny:
                return Data("{\"permission\":\"deny\",\"user_message\":\"Denied from Agent Island\"}".utf8)
            }
        }

        var decisionObject: [String: Any]
        switch decision {
        case .terminal:
            return nil // no output → Claude Code shows its normal prompt
        case .allow:
            decisionObject = ["behavior": "allow"]
        case .alwaysAllow:
            decisionObject = ["behavior": "allow"]
            if let permissions = request.alwaysAllowPermissions,
               let array = try? JSONSerialization.jsonObject(with: permissions) {
                decisionObject["updatedPermissions"] = array
            }
        case .deny:
            decisionObject = [
                "behavior": "deny",
                "message": "The user denied this from the Notchly notch."
            ]
        }

        let output: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decisionObject
            ]
        ]
        return try? JSONSerialization.data(withJSONObject: output, options: [.withoutEscapingSlashes])
    }

    /// Keeps only the suggestions that grant access (rules/directories). Never forwards
    /// mode switches, so "Always allow" can't silently flip a session into bypass mode.
    static func alwaysAllowPermissions(from suggestionsJSON: Data?) -> Data? {
        guard let suggestionsJSON,
              let suggestions = (try? JSONSerialization.jsonObject(with: suggestionsJSON)) as? [[String: Any]] else {
            return nil
        }
        let safe = suggestions.filter { entry in
            switch entry["type"] as? String {
            case "addRules": return entry["behavior"] as? String == "allow"
            case "addDirectories": return true
            default: return false
            }
        }
        guard !safe.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: safe)
    }

    // MARK: - Tool description

    static func describe(toolName: String?, input: [String: Any]?, cwd: String) -> (String, String?) {
        let input = input ?? [:]
        func string(_ key: String) -> String? {
            (input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func relative(_ path: String) -> String {
            guard !cwd.isEmpty, path.hasPrefix(cwd + "/") else { return path }
            return String(path.dropFirst(cwd.count + 1))
        }

        let summary: String
        var detail: String?

        switch toolName ?? "" {
        case "Bash":
            summary = string("command") ?? "shell command"
            detail = string("description")
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit":
            summary = relative(string("file_path") ?? string("notebook_path") ?? "file")
            if toolName == "Write", let content = input["content"] as? String {
                detail = "\(content.split(separator: "\n", omittingEmptySubsequences: false).count) lines"
            }
        case "WebFetch":
            summary = string("url") ?? "web page"
            detail = string("prompt")
        case "WebSearch":
            summary = string("query") ?? "web search"
        case "Glob", "Grep":
            summary = string("pattern") ?? "search"
            detail = string("path").map(relative)
        default:
            summary = input.values.compactMap { $0 as? String }.first ?? (toolName ?? "tool")
        }

        let clipped = summary.count > 400 ? String(summary.prefix(400)) + "…" : summary
        return (clipped.replacingOccurrences(of: "\n", with: " ⏎ "), detail)
    }
}
