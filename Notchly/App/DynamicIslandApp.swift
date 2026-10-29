//
//  DynamicIslandApp.swift
//  Notchly
//
//  Created by n0xbyte on 16.03.2026.
//

import SwiftUI

@main
struct DynamicIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                settingsManager: appDelegate.environment.settingsManager,
                codexHookIntegrationManager: appDelegate.environment.codexHookIntegrationManager,
                claudeHookIntegrationManager: appDelegate.environment.claudeHookIntegrationManager,
                cursorHookIntegrationManager: appDelegate.environment.cursorHookIntegrationManager,
                lockScreenIdentityManager: appDelegate.environment.lockScreenIdentityManager
            )
            .frame(minWidth: 860, minHeight: 680)
        }
    }
}
