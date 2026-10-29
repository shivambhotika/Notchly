//
//  AgentBridgeServer.swift
//  Notchly
//
//  Two-way bridge between coding-agent hooks (Claude Code first) and the notch.
//
//  Design notes (vs. the one-way agent-events.jsonl file):
//  - A hook connects over a Unix socket, writes one header line, the raw hook
//    payload JSON, and an ASCII record separator (0x1E). No parsing happens in
//    the shell, so the hook needs nothing beyond /bin/sh and /usr/bin/nc.
//  - For PermissionRequest the connection is held open until the user answers
//    in the notch, the request times out, or the hook process goes away. The
//    reply (possibly empty) is written back and the socket is closed. Empty
//    reply = "no decision" so Claude Code falls back to its normal prompt.
//  - The socket lives in the user's Application Support folder with 0600
//    permissions, so other local users cannot approve tool calls.
//
//  Protocol idea adapted from ai-island (Apache-2.0, VoidLight00), which in
//  turn derives from claude-island (Apache-2.0, Farouq Aldori). See NOTICE.
//

import Foundation
import Darwin

nonisolated struct AgentHookPayload: Sendable {
    let source: String
    let hookArgument: String
    let hookEventName: String
    let sessionID: String
    let cwd: String
    let toolName: String?
    let toolInputJSON: Data?
    let toolInputFingerprint: String?
    let notificationType: String?
    let message: String?
    let permissionSuggestionsJSON: Data?

    var expectsDecision: Bool {
        hookEventName == "PermissionRequest"
    }

    var toolInput: [String: Any]? {
        guard let toolInputJSON else { return nil }
        return (try? JSONSerialization.jsonObject(with: toolInputJSON)) as? [String: Any]
    }
}

nonisolated struct AgentBridgeMessage: Sendable {
    let connectionID: UUID
    let payload: AgentHookPayload
}

nonisolated final class AgentBridgeServer: @unchecked Sendable {
    typealias MessageHandler = @Sendable (AgentBridgeMessage) -> Void
    typealias ReleaseHandler = @Sendable (_ connectionID: UUID) -> Void

    /// Called on the main queue for every hook message.
    var onMessage: MessageHandler?
    /// Called on the main queue when a held request ends without a notch decision
    /// (timeout or the hook process went away, e.g. answered in the terminal).
    var onReleased: ReleaseHandler?

    /// How long a PermissionRequest waits in the notch before handing back to the terminal.
    var decisionTimeout: TimeInterval = 90

    private let queue = DispatchQueue(label: "notchly.agent-bridge", qos: .userInitiated)
    private let clientQueue = DispatchQueue(label: "notchly.agent-bridge.clients", qos: .userInitiated, attributes: .concurrent)
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var livenessTimer: DispatchSourceTimer?
    private var pending: [UUID: PendingConnection] = [:]   // guarded by `queue`

    private struct PendingConnection {
        let fd: Int32
        let deadline: Date
    }

    static let recordSeparator: UInt8 = 0x1E
    static let maxMessageBytes = 4 * 1024 * 1024

    static var socketURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notchly", isDirectory: true)
            .appendingPathComponent("agent.sock")
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [self] in
            guard listenFD < 0 else { return }
            openListener()
        }
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            livenessTimer?.cancel()
            livenessTimer = nil
            for (_, connection) in pending {
                close(connection.fd)
            }
            pending.removeAll()
            unlink(Self.socketURL.path)
        }
    }

    /// Writes `response` (may be nil = no decision) to a held connection and closes it.
    func respond(to connectionID: UUID, with response: Data?) {
        queue.async { [self] in
            guard let connection = pending.removeValue(forKey: connectionID) else { return }
            if let response, !response.isEmpty {
                Self.writeAll(response + Data([0x0A]), to: connection.fd)
            }
            close(connection.fd)
        }
    }

    // MARK: - Listener

    private func openListener() {
        let path = Self.socketURL.path
        try? FileManager.default.createDirectory(
            at: Self.socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            close(fd)
            return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }

        // Create the socket file owner-only from the start.
        let previousMask = umask(0o077)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        _ = umask(previousMask)

        guard bindResult == 0, listen(fd, 16) == 0 else {
            close(fd)
            return
        }
        _ = chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPendingClients() }
        source.setCancelHandler { [weak self] in
            close(fd)
            self?.listenFD = -1
        }
        acceptSource = source
        source.resume()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.checkPendingConnections() }
        livenessTimer = timer
        timer.resume()
    }

    private func acceptPendingClients() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }

            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            // Accepted sockets inherit O_NONBLOCK on Darwin; reads below are blocking with a timeout.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            clientQueue.async { [weak self] in
                self?.readMessage(from: client)
            }
        }
    }

    // MARK: - Reading

    private func readMessage(from fd: Int32) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while data.count < Self.maxMessageBytes {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                let chunk = buffer[0..<count]
                if let separator = chunk.firstIndex(of: Self.recordSeparator) {
                    data.append(contentsOf: buffer[0..<separator])
                    break
                }
                data.append(contentsOf: chunk)
            } else {
                break // EOF, timeout or error: parse what we have
            }
        }

        guard let payload = Self.parse(data) else {
            close(fd)
            return
        }

        let connectionID = UUID()
        if payload.expectsDecision {
            queue.async { [self] in
                pending[connectionID] = PendingConnection(
                    fd: fd,
                    deadline: Date().addingTimeInterval(decisionTimeout)
                )
            }
        } else {
            close(fd)
        }

        let message = AgentBridgeMessage(connectionID: connectionID, payload: payload)
        DispatchQueue.main.async { [weak self] in
            self?.onMessage?(message)
        }
    }

    /// Releases held requests that timed out or whose hook process disappeared.
    private func checkPendingConnections() {
        guard !pending.isEmpty else { return }
        let now = Date()
        var released: [UUID] = []

        for (id, connection) in pending {
            if now >= connection.deadline || Self.peerHasClosed(connection.fd) {
                close(connection.fd)
                released.append(id)
            }
        }

        guard !released.isEmpty else { return }
        released.forEach { pending.removeValue(forKey: $0) }
        DispatchQueue.main.async { [weak self] in
            released.forEach { self?.onReleased?($0) }
        }
    }

    private static func peerHasClosed(_ fd: Int32) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 0) > 0 else { return false }
        if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return true }
        var byte: UInt8 = 0
        return recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0
    }

    private static func writeAll(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                guard written > 0 else { return }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
    }

    // MARK: - Parsing

    /// Message = header JSON line, newline, raw hook payload JSON.
    static func parse(_ data: Data) -> AgentHookPayload? {
        guard let newline = data.firstIndex(of: 0x0A) else { return nil }
        let headerData = data[data.startIndex..<newline]
        let bodyData = data[data.index(after: newline)...]

        guard let header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any] else {
            return nil
        }
        let body = (try? JSONSerialization.jsonObject(with: Data(bodyData))) as? [String: Any] ?? [:]

        let toolInput = body["tool_input"]
        let toolInputJSON = toolInput.flatMap { object -> Data? in
            guard JSONSerialization.isValidJSONObject(object) else { return nil }
            return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        let suggestions = body["permission_suggestions"].flatMap { object -> Data? in
            guard JSONSerialization.isValidJSONObject(object) else { return nil }
            return try? JSONSerialization.data(withJSONObject: object)
        }
        let toolName = body["tool_name"] as? String

        return AgentHookPayload(
            source: (header["source"] as? String) ?? "claude",
            hookArgument: (header["kind"] as? String) ?? "",
            hookEventName: (body["hook_event_name"] as? String) ?? "",
            sessionID: (body["session_id"] as? String) ?? "",
            cwd: (body["cwd"] as? String) ?? "",
            toolName: toolName,
            toolInputJSON: toolInputJSON,
            toolInputFingerprint: toolInputJSON.map { "\(toolName ?? ""):\($0.hashValue)" },
            notificationType: (body["notification_type"] as? String) ?? (body["type"] as? String),
            message: body["message"] as? String,
            permissionSuggestionsJSON: suggestions
        )
    }
}
