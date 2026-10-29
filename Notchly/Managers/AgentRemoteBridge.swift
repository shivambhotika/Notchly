//
//  AgentRemoteBridge.swift
//  Notchly
//
//  Syncs agent state to the Agent Island relay and applies phone → Mac commands.
//

import Foundation
import Combine

@MainActor
final class AgentRemoteBridge {
    private let settingsManager: SettingsManager
    private let agentEventManager: AgentEventManager
    private let agentSessionStore: AgentSessionStore
    private let musicManager: MusicManager

    private var pushTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var lastPushedFingerprint = 0
    private var debouncedPushTask: Task<Void, Never>?
    private var lastRelayActivityBySource: [String: Date] = [:]

    init(
        settingsManager: SettingsManager,
        agentEventManager: AgentEventManager,
        agentSessionStore: AgentSessionStore,
        musicManager: MusicManager
    ) {
        self.settingsManager = settingsManager
        self.agentEventManager = agentEventManager
        self.agentSessionStore = agentSessionStore
        self.musicManager = musicManager
    }

    func start() {
        guard pushTask == nil else { return }

        agentEventManager.objectWillChange
            .sink { [weak self] in
                self?.noteRelayActivityFromCurrentEvent()
                self?.schedulePush()
            }
            .store(in: &cancellables)

        agentSessionStore.objectWillChange
            .sink { [weak self] in
                self?.noteRelayActivityFromSessions()
                self?.schedulePush()
            }
            .store(in: &cancellables)

        pushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await self?.pushStateIfNeeded(force: false)
            }
        }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollCommands()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }

        schedulePush()
    }

    func stop() {
        pushTask?.cancel()
        pollTask?.cancel()
        debouncedPushTask?.cancel()
        pushTask = nil
        pollTask = nil
        debouncedPushTask = nil
        cancellables.removeAll()
    }

    func pushOfflineState() {
        guard settingsManager.agentRelayEnabled,
              let endpoint = AgentRelayURL.normalizeBase(settingsManager.agentRelayEndpointURL) else { return }

        var stateObject: [String: Any] = [
            "macOnline": false,
            "activeAgents": [] as [Any],
        ]
        if let encoded = try? JSONEncoder().encode(buildState()),
           let built = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] {
            stateObject["macVolume"] = built["macVolume"]
            stateObject["macMuted"] = built["macMuted"]
            stateObject["pendingApproval"] = built["pendingApproval"]
        }

        guard let body = try? JSONSerialization.data(withJSONObject: ["state": stateObject]) else { return }
        var request = URLRequest(url: AgentRelayURL.apiPath(base: endpoint, path: "v1/events"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settingsManager.agentRelaySharedSecret, forHTTPHeaderField: "X-Relay-Secret")
        request.httpBody = body
        request.timeoutInterval = 0.4

        let group = DispatchGroup()
        group.enter()
        URLSession.shared.dataTask(with: request) { _, _, _ in group.leave() }.resume()
        _ = group.wait(timeout: .now() + 0.45)
    }

    func pushStateIfNeeded(force: Bool) async {
        await pushState(macOnline: true, force: force)
    }

    private func pushState(macOnline: Bool, force: Bool) async {
        guard settingsManager.agentRelayEnabled else { return }
        guard let endpoint = AgentRelayURL.normalizeBase(settingsManager.agentRelayEndpointURL) else { return }

        var state = buildState()
        if !macOnline {
            state = AgentRelayState(
                activeAgents: [],
                latestEvent: state.latestEvent,
                pendingApproval: state.pendingApproval,
                macVolume: state.macVolume,
                macMuted: state.macMuted
            )
        }

        let fingerprint = stateFingerprint(state, macOnline: macOnline)
        if !force, fingerprint == lastPushedFingerprint { return }

        do {
            let encoded = try JSONEncoder().encode(state)
            var stateObject = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
            stateObject["macOnline"] = macOnline
            try await postJSON(
                url: AgentRelayURL.apiPath(base: endpoint, path: "v1/events"),
                secret: settingsManager.agentRelaySharedSecret,
                body: ["state": stateObject]
            )
            lastPushedFingerprint = fingerprint
        } catch {
            debugLog("push failed: \(error.localizedDescription)")
        }
    }

    private func schedulePush() {
        debouncedPushTask?.cancel()
        debouncedPushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self?.pushStateIfNeeded(force: true)
        }
    }

    private func pollCommands() async {
        guard settingsManager.agentRelayEnabled else { return }
        guard let endpoint = AgentRelayURL.normalizeBase(settingsManager.agentRelayEndpointURL) else { return }

        do {
            let data = try await getJSON(
                url: AgentRelayURL.apiPath(base: endpoint, path: "v1/commands/pending"),
                secret: settingsManager.agentRelaySharedSecret
            )
            guard
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let commands = object["commands"] as? [[String: Any]]
            else { return }

            for entry in commands {
                guard let commandObject = entry["command"] as? [String: Any] else { continue }
                let commandData = try JSONSerialization.data(withJSONObject: commandObject)
                let command = try JSONDecoder().decode(AgentRelayCommand.self, from: commandData)
                apply(command)
            }
        } catch {
            debugLog("poll failed: \(error.localizedDescription)")
        }
    }

    private func apply(_ command: AgentRelayCommand) {
        switch command.type {
        case "approval":
            guard
                let idString = command.approvalId,
                let uuid = UUID(uuidString: idString),
                let decisionRaw = command.decision
            else { return }
            let decision: AgentApprovalDecision
            switch decisionRaw {
            case "allow": decision = .allow
            case "always_allow", "alwaysAllow": decision = .alwaysAllow
            case "deny": decision = .deny
            default: return
            }
            _ = agentSessionStore.resolveRemoteApproval(id: uuid, decision: decision)

        case "audio":
            if command.action == "set_volume", let value = command.value {
                musicManager.applyRemoteVolume(percent: value)
                schedulePush()
            } else if command.action == "set_muted", let muted = command.muted {
                musicManager.applyRemoteMute(muted)
                schedulePush()
            }

        default:
            break
        }
    }

    func buildState() -> AgentRelayState {
        noteRelayActivityFromSessions()
        noteRelayActivityFromCurrentEvent()

        let badges = relayAgentBadges()
        pruneStaleRelayActivity(activeBadges: badges)
        let latestEvent = relayLatestEvent(activeBadges: badges)

        var pending: AgentRelayPendingApproval?
        if let request = agentSessionStore.currentApproval {
            pending = AgentRelayPendingApproval(
                approvalId: request.id.uuidString,
                agent: request.source.lowercased(),
                toolName: request.displayToolName,
                summary: request.summary,
                detail: request.detail,
                canAlwaysAllow: request.canAlwaysAllow
            )
        }

        let volumePercent = Int((musicManager.outputVolume * 100).rounded())
        return AgentRelayState(
            activeAgents: badges,
            latestEvent: latestEvent,
            pendingApproval: pending,
            macVolume: min(max(volumePercent, 0), 100),
            macMuted: musicManager.isOutputMuted
        )
    }

    private func relayAgentBadges() -> [AgentRelayAgentBadge] {
        var badges: [AgentRelayAgentBadge] = []
        var seen = Set<String>()
        let cutoff = Date().addingTimeInterval(-Self.relayActivityMaxAge)

        for session in agentSessionStore.relayActiveSessions {
            let source = session.source.lowercased()
            guard !seen.contains(source) else { continue }
            seen.insert(source)
            badges.append(AgentRelayAgentBadge(
                source: source,
                label: relayLabel(for: source),
                accent: relayAccent(for: source)
            ))
        }

        for (source, seenAt) in lastRelayActivityBySource where seenAt > cutoff {
            guard !seen.contains(source) else { continue }
            seen.insert(source)
            badges.append(AgentRelayAgentBadge(
                source: source,
                label: relayLabel(for: source),
                accent: relayAccent(for: source)
            ))
        }

        return badges
    }

    private func relayLatestEvent(activeBadges: [AgentRelayAgentBadge]) -> AgentRelayEvent? {
        if let event = agentEventManager.currentEvent, Self.isRelayVisibleEvent(event) {
            return AgentRelayEvent(
                type: relayEventType(for: event.kind),
                agent: event.source.lowercased(),
                title: event.title,
                message: event.message,
                timestamp: ISO8601DateFormatter().string(from: event.createdAt)
            )
        }

        guard activeBadges.isEmpty else { return nil }
        return nil
    }

    private func noteRelayActivityFromSessions() {
        let now = Date()
        for session in agentSessionStore.relayActiveSessions {
            lastRelayActivityBySource[session.source.lowercased()] = now
        }
    }

    private func noteRelayActivityFromCurrentEvent() {
        guard let event = agentEventManager.currentEvent, Self.isRelayVisibleEvent(event) else { return }
        lastRelayActivityBySource[event.source.lowercased()] = Date()
    }

    private func pruneStaleRelayActivity(activeBadges: [AgentRelayAgentBadge]) {
        let active = Set(activeBadges.map { $0.source.lowercased() })
        let cutoff = Date().addingTimeInterval(-Self.relayActivityMaxAge)
        lastRelayActivityBySource = lastRelayActivityBySource.filter { source, seenAt in
            active.contains(source) || seenAt > cutoff
        }
    }

    private static let relayActivityMaxAge: TimeInterval = 3 * 60

    private static func isRelayVisibleEvent(_ event: AgentEvent) -> Bool {
        guard event.createdAt > Date().addingTimeInterval(-relayActivityMaxAge) else { return false }
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

    private func relayLabel(for source: String) -> String {
        switch source {
        case "codex": return "Codex"
        case "claude": return "Claude"
        case "cursor": return "Cursor"
        default: return source.capitalized
        }
    }

    private func relayAccent(for source: String) -> String {
        switch source {
        case "codex": return "#10A37F"
        case "claude": return "#D97757"
        case "cursor": return "#7C3AED"
        default: return "#FFFFFF"
        }
    }

    private func stateFingerprint(_ state: AgentRelayState, macOnline: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(macOnline)
        hasher.combine(state.latestEvent?.title)
        hasher.combine(state.latestEvent?.type)
        hasher.combine(state.pendingApproval?.approvalId)
        hasher.combine(state.macVolume)
        hasher.combine(state.macMuted)
        hasher.combine(state.activeAgents.count)
        for badge in state.activeAgents.sorted(by: { $0.source < $1.source }) {
            hasher.combine(badge.source)
        }
        return hasher.finalize()
    }

    private func postJSON(url: URL, secret: String, body: [String: Any]) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(secret, forHTTPHeaderField: "X-Relay-Secret")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private func getJSON(url: URL, secret: String) async throws -> Data {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items.append(URLQueryItem(name: "secret", value: secret))
        components?.queryItems = items
        guard let finalURL = components?.url else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: finalURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        print("[AgentRemoteBridge] \(message)")
        #endif
    }
}
