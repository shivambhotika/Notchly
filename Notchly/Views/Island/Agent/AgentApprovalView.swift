//
//  AgentApprovalView.swift
//  Notchly
//
//  The interactive card shown in the island while an agent waits for permission.
//

import SwiftUI

struct AgentApprovalView: View {
    let request: AgentApprovalRequest
    let queuedCount: Int
    let size: CGSize
    let onDecision: (AgentApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            commandPreview
            actions
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .frame(width: size.width, height: size.height, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 7) {
            AgentSourceGlyph(source: request.source)

            Text(request.displayToolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Text(request.projectName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)

            Spacer(minLength: 4)

            if queuedCount > 0 {
                Text("+\(queuedCount)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange))
            }
        }
    }

    private var commandPreview: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(request.summary)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(2)
                .truncationMode(.middle)

            if let detail = request.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
    }

    private var actions: some View {
        HStack(spacing: 6) {
            ApprovalButton(title: "Deny", shortcut: "⌥⌘N", style: .destructive) {
                onDecision(.deny)
            }
            ApprovalButton(title: "Terminal", shortcut: "⌥⌘T", style: .quiet) {
                onDecision(.terminal)
            }
            Spacer(minLength: 0)
            if request.canAlwaysAllow {
                ApprovalButton(title: "Always", shortcut: "⌥⌘A", style: .secondary) {
                    onDecision(.alwaysAllow)
                }
            }
            ApprovalButton(title: "Allow", shortcut: "⌥⌘Y", style: .primary) {
                onDecision(.allow)
            }
        }
    }
}

private struct ApprovalButton: View {
    enum Style { case primary, secondary, destructive, quiet }

    let title: String
    let shortcut: String
    let style: Style
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(
                Capsule(style: .continuous)
                    .fill(background.opacity(isHovered ? 1 : 0.85))
            )
            .contentShape(Capsule())
            .onHover { isHovered = $0 }
            // The island lives in a non-activating panel; this NSView click
            // catcher reliably receives first-mouse clicks where Button may not.
            .overlay { IslandClickCatcher(onClick: action) }
            .help("\(title) (\(shortcut))")
    }

    private var foreground: Color {
        switch style {
        case .primary: return .black
        case .secondary, .quiet: return .white.opacity(0.9)
        case .destructive: return Color(red: 1.0, green: 0.55, blue: 0.52)
        }
    }

    private var background: Color {
        switch style {
        case .primary: return Color(red: 0.36, green: 0.86, blue: 0.52)
        case .secondary: return Color.white.opacity(0.16)
        case .destructive: return Color(red: 1.0, green: 0.3, blue: 0.27).opacity(0.18)
        case .quiet: return Color.white.opacity(0.06)
        }
    }
}

/// Small source badge, reused by the approval card.
struct AgentSourceGlyph: View {
    let source: String

    var body: some View {
        switch source.lowercased() {
        case "codex":
            Image("CodexAgentIcon").resizable().scaledToFit().frame(width: 16, height: 16)
        case "cursor":
            Image("CursorAgentIcon").resizable().scaledToFit().frame(width: 16, height: 16)
        default:
            Circle()
                .fill(Color(red: 0.85, green: 0.48, blue: 0.32)) // Claude terracotta
                .frame(width: 8, height: 8)
                .frame(width: 16, height: 16)
        }
    }
}
