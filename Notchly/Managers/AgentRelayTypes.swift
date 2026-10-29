//
//  AgentRelayTypes.swift
//  Notchly
//
//  JSON shapes shared with the Agent Island relay and iPhone app.
//

import Foundation

struct AgentRelayAgentBadge: Codable, Equatable {
    let source: String
    let label: String
    let accent: String
}

struct AgentRelayEvent: Codable, Equatable {
    let type: String
    let agent: String
    let title: String
    let message: String?
    let timestamp: String
}

struct AgentRelayPendingApproval: Codable, Equatable {
    let approvalId: String
    let agent: String
    let toolName: String
    let summary: String
    let detail: String?
    let canAlwaysAllow: Bool
}

struct AgentRelayMacSummary: Codable, Equatable, Hashable {
    let macId: String
    let name: String
    let presence: String
    let macOnline: Bool
    var macVolume: Int?
    var macMuted: Bool?
    var updatedAt: String?
}

struct AgentRelayState: Codable, Equatable {
    var activeAgents: [AgentRelayAgentBadge]
    var latestEvent: AgentRelayEvent?
    var pendingApproval: AgentRelayPendingApproval?
    var macVolume: Int?
    var macMuted: Bool?
    var macId: String?
    var macName: String?
    var macPresence: String?
    var suggestedPollSeconds: Int?
    var apnsAvailable: Bool?
    var macs: [AgentRelayMacSummary]?
    var preferredMacId: String?
}

struct AgentRelayCommand: Decodable {
    let type: String
    let approvalId: String?
    let decision: String?
    let value: Int?
    let muted: Bool?
    let action: String?
    let macId: String?
    let enabled: Bool?
}
