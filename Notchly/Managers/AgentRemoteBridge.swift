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
    private let brightnessManager: BrightnessManager
    private let presenceService: RelayPresenceService
    private let presenceMonitor: MacRelayPresenceMonitor

    private var pushTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var lastPushedFingerprint = 0
    private var debouncedPushTask: Task<Void, Never>?

    init(
        settingsManager: SettingsManager,
        agentEventManager: AgentEventManager,
        agentSessionStore: AgentSessionStore,
        musicManager: MusicManager,
        brightnessManager: BrightnessManager,
        presenceService: RelayPresenceService,
        presenceMonitor: MacRelayPresenceMonitor
    ) {
        self.settingsManager = settingsManager
        self.agentEventManager = agentEventManager
        self.agentSessionStore = agentSessionStore
        self.musicManager = musicManager
        self.brightnessManager = brightnessManager
        self.presenceService = presenceService
        self.presenceMonitor = presenceMonitor
    }

    func start() {
        guard pushTask == nil else { return }

        agentEventManager.objectWillChange
            .sink { [weak self] in self?.schedulePush() }
            .store(in: &cancellables)

        agentSessionStore.objectWillChange
            .sink { [weak self] in self?.schedulePush() }
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
        presenceMonitor.markOffline()
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
                macMuted: state.macMuted,
                macId: state.macId,
                macName: state.macName,
                macPresence: MacRelayPresence.offline.rawValue,
                suggestedPollSeconds: 30,
                apnsAvailable: state.apnsAvailable,
                macs: state.macs,
                preferredMacId: state.preferredMacId
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
        if let targetMac = command.macId, !targetMac.isEmpty, targetMac != settingsManager.agentRelayMacId {
            return
        }

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

        case "media":
            if command.action == "toggle_play_pause" {
                musicManager.togglePlay()
                schedulePush()
            }

        case "display":
            if command.action == "set_brightness", let value = command.value {
                brightnessManager.applyRemoteBrightness(percent: value)
                schedulePush()
            }

        case "pairing":
            if command.action == "select_mac", let macId = command.macId {
                settingsManager.agentRelayPreferredMacId = macId
                schedulePush()
            }

        default:
            break
        }
    }

    func buildState() -> AgentRelayState {
        let badges = presenceService.activeBadges()
        let latestEvent = presenceService.latestEvent(activeBadges: badges)

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
        let presence = presenceMonitor.presence.rawValue
        let pollHint = pending != nil ? 2 : (presence == MacRelayPresence.asleep.rawValue ? 15 : 8)

        return AgentRelayState(
            activeAgents: badges,
            latestEvent: latestEvent,
            pendingApproval: pending,
            macVolume: min(max(volumePercent, 0), 100),
            macMuted: musicManager.isOutputMuted,
            macId: settingsManager.agentRelayMacId,
            macName: presenceMonitor.macName,
            macPresence: presence,
            suggestedPollSeconds: pollHint,
            apnsAvailable: nil,
            macs: nil,
            preferredMacId: settingsManager.agentRelayPreferredMacId
        )
    }

    private func stateFingerprint(_ state: AgentRelayState, macOnline: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(macOnline)
        hasher.combine(state.latestEvent?.title)
        hasher.combine(state.latestEvent?.type)
        hasher.combine(state.pendingApproval?.approvalId)
        hasher.combine(state.macVolume)
        hasher.combine(state.macMuted)
        hasher.combine(state.macPresence)
        hasher.combine(state.macId)
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
