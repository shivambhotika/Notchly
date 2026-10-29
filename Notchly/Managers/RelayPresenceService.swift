//
//  RelayPresenceService.swift
//  Notchly
//
//  Single source of truth for which agents appear on the iPhone relay.
//

import Foundation

@MainActor
final class RelayPresenceService {
    private let agentSessionStore: AgentSessionStore
    private let agentEventManager: AgentEventManager

    static let sessionActivityMaxAge: TimeInterval = 90

    init(agentSessionStore: AgentSessionStore, agentEventManager: AgentEventManager) {
        self.agentSessionStore = agentSessionStore
        self.agentEventManager = agentEventManager
    }

    func activeBadges() -> [AgentRelayAgentBadge] {
        var badges: [AgentRelayAgentBadge] = []
        var seen = Set<String>()

        for session in agentSessionStore.relayActiveSessions {
            let source = session.source.lowercased()
            guard !seen.contains(source) else { continue }
            seen.insert(source)
            badges.append(AgentRelayAgentBadge(
                source: source,
                label: Self.label(for: source),
                accent: Self.accent(for: source)
            ))
        }

        // Match the notch: only show jsonl-driven agents while their live event is still active.
        if let event = agentEventManager.currentEvent, isVisibleEvent(event) {
            let source = event.source.lowercased()
            if !seen.contains(source) {
                seen.insert(source)
                badges.append(AgentRelayAgentBadge(
                    source: source,
                    label: Self.label(for: source),
                    accent: Self.accent(for: source)
                ))
            }
        }

        return badges.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    func latestEvent(activeBadges: [AgentRelayAgentBadge]) -> AgentRelayEvent? {
        guard let event = agentEventManager.currentEvent, isVisibleEvent(event) else {
            return nil
        }
        return AgentRelayEvent(
            type: relayEventType(for: event.kind),
            agent: event.source.lowercased(),
            title: event.title,
            message: event.message,
            timestamp: ISO8601DateFormatter().string(from: event.createdAt)
        )
    }

    private func isVisibleEvent(_ event: AgentEvent) -> Bool {
        switch event.kind {
        case .clear, .completed, .failed, .cancelled: return false
        case .accessRequest, .waiting, .started, .progress: return true
        }
    }

    private func relayEventType(for kind: AgentEventKind) -> String {
        switch kind {
        case .accessRequest: return "needs_approval"
        case .completed: return "task_completed"
        case .waiting: return "waiting"
        case .failed: return "failed"
        case .started, .progress: return "status"
        case .clear: return "clear"
        case .cancelled: return "cancelled"
        }
    }

    static func label(for source: String) -> String {
        switch source.lowercased() {
        case "codex": return "Codex"
        case "claude": return "Claude"
        case "cursor": return "Cursor"
        case "grok": return "Grok"
        case "autorouter": return "AutoRouter"
        case "t3": return "T3"
        default: return source.capitalized
        }
    }

    static func accent(for source: String) -> String {
        switch source.lowercased() {
        case "codex": return "#10A37F"
        case "claude": return "#D97757"
        case "cursor": return "#7C3AED"
        case "grok": return "#F97316"
        case "autorouter": return "#0EA5E9"
        case "t3": return "#E11D48"
        default: return "#A3A3A3"
        }
    }
}
