//
//  MacRelayPresenceMonitor.swift
//  Notchly
//

import AppKit
import Combine

enum MacRelayPresence: String, Codable {
    case online
    case asleep
    case offline
}

@MainActor
final class MacRelayPresenceMonitor: ObservableObject {
    @Published private(set) var presence: MacRelayPresence = .online

    private var cancellables = Set<AnyCancellable>()

    var macName: String {
        Host.current().localizedName ?? "Mac"
    }

    func start() {
        presence = .online
        let workspace = NSWorkspace.shared
        workspace.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in self?.presence = .asleep }
            .store(in: &cancellables)
        workspace.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.presence = .online }
            .store(in: &cancellables)
        DistributedNotificationCenter.default().publisher(for: .init("com.apple.screenIsLocked"))
            .sink { [weak self] _ in self?.presence = .asleep }
            .store(in: &cancellables)
        DistributedNotificationCenter.default().publisher(for: .init("com.apple.screenIsUnlocked"))
            .sink { [weak self] _ in self?.presence = .online }
            .store(in: &cancellables)
    }

    func markOffline() {
        presence = .offline
    }
}
