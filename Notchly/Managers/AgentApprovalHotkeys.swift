//
//  AgentApprovalHotkeys.swift
//  Notchly
//
//  Global shortcuts for answering a notch approval without touching the mouse.
//  Registered only while a request is pending, so they never shadow app
//  shortcuts the rest of the time. Carbon hot keys need no Accessibility grant.
//
//    ⌥⌘Y  Allow        ⌥⌘A  Always allow
//    ⌥⌘N  Deny         ⌥⌘T  Answer in terminal
//

import Carbon.HIToolbox
import Foundation

@MainActor
final class AgentApprovalHotkeys {
    var onDecision: ((AgentApprovalDecision) -> Void)?

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?

    private static let signature: OSType = 0x4E54_4C59 // 'NTLY'
    private static let bindings: [(id: UInt32, keyCode: Int, decision: AgentApprovalDecision)] = [
        (1, kVK_ANSI_Y, .allow),
        (2, kVK_ANSI_A, .alwaysAllow),
        (3, kVK_ANSI_N, .deny),
        (4, kVK_ANSI_T, .terminal)
    ]

    var isRegistered: Bool { !hotKeyRefs.isEmpty }

    func register() {
        guard !isRegistered else { return }
        installHandlerIfNeeded()

        let modifiers = UInt32(cmdKey | optionKey)
        for binding in Self.bindings {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: binding.id)
            let status = RegisterEventHotKey(
                UInt32(binding.keyCode),
                modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
            }
        }
    }

    func unregister() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs.removeAll()
    }

    fileprivate func handleHotKey(id: UInt32) {
        guard let binding = Self.bindings.first(where: { $0.id == id }) else { return }
        onDecision?(binding.decision)
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()

        _ = InstallEventHandler(
            GetApplicationEventTarget(),
            agentHotKeyEventHandler,
            1,
            &eventType,
            context,
            &handlerRef
        )
    }
}

/// Carbon delivers hot-key events on the main thread.
private nonisolated func agentHotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == 0x4E54_4C59 else {
        return OSStatus(eventNotHandledErr)
    }

    let id = hotKeyID.id
    let address = UInt(bitPattern: userData)
    MainActor.assumeIsolated {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
        let hotkeys = Unmanaged<AgentApprovalHotkeys>.fromOpaque(pointer).takeUnretainedValue()
        hotkeys.handleHotKey(id: id)
    }
    return noErr
}
