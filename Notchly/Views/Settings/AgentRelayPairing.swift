//
//  AgentRelayPairing.swift
//  Notchly
//

import AppKit
import CoreImage
import Foundation
import Security
import SwiftUI

struct AgentRelayPairingPayload: Codable {
    let v: Int
    let relayURL: String
    let secret: String
}

enum AgentRelayPairing {
    static func makePayload(relayURL: String, secret: String) -> String {
        let payload = AgentRelayPairingPayload(v: 1, relayURL: relayURL, secret: secret)
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func generateSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum QRCodeGenerator {
    static func nsImage(from string: String, dimension: CGFloat = 168) -> NSImage? {
        let data = Data(string.utf8)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = dimension / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

struct AgentRelayPairingQRView: View {
    let payload: String

    var body: some View {
        VStack(spacing: 8) {
            if let image = QRCodeGenerator.nsImage(from: payload) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 168, height: 168)
            }
            Text("Scan in Agent Island on your iPhone")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
