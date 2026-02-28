//
//  StartupSyncModifier.swift
//  ExcalidrawZ
//
//  Created by Claude on 2025/12/30.
//

import SwiftUI
import Logging

private enum StartupStorageSelection: String {
    case iCloud
    case webdav
    case localOnly
}

private enum StartupMigrationStage: Int {
    case notStarted = 0
    case dryRunCompleted = 1
    case writesConfirmed = 2
}

/// View modifier that enables FileStorage sync after migration completes.
/// Includes startup decision flow for iCloud/WebDAV/local fallback.
struct StartupSyncModifier: ViewModifier {
    private let logger = Logger(label: "StartupSyncModifier")

    @EnvironmentObject private var migrationState: MigrationState

    @AppStorage("StartupStorageSelection") private var startupStorageSelectionRaw = StartupStorageSelection.iCloud.rawValue
    @AppStorage("WebDAVConfigured") private var isWebDAVConfigured = false
    @AppStorage("WebDAVSelected") private var isWebDAVSelected = false
    @AppStorage("WebDAVMigrationVersion") private var webDAVMigrationVersion = 0
    @AppStorage("WebDAVMigrationStage") private var webDAVMigrationStageRaw = StartupMigrationStage.notStarted.rawValue

    @State private var hasHandledStartup = false
    @State private var showWebDAVFallbackChooser = false
    @State private var showWebDAVDryRunPrompt = false
    @State private var dryRunReport: SyncDryRunReport?

    func body(content: Content) -> some View {
        content
            .onChange(of: migrationState.phase) { newPhase in
                if newPhase == .closed && !hasHandledStartup {
                    hasHandledStartup = true
                    Task {
                        await runStartupDecisionFlow()
                    }
                }
            }
            .alert(
                String(localized: "startup.webdav.fallback.title"),
                isPresented: $showWebDAVFallbackChooser
            ) {
                Button(String(localized: "startup.webdav.fallback.localOnly"), role: .cancel) {
                    startupStorageSelectionRaw = StartupStorageSelection.localOnly.rawValue
                }
                Button(String(localized: "startup.webdav.fallback.configure")) {
                    startupStorageSelectionRaw = StartupStorageSelection.webdav.rawValue
                    isWebDAVSelected = true
                }
            } message: {
                Text(String(localized: "startup.webdav.fallback.message"))
            }
            .alert(
                String(localized: "startup.webdav.dryRun.title"),
                isPresented: $showWebDAVDryRunPrompt
            ) {
                Button(String(localized: "startup.webdav.dryRun.confirm")) {
                    Task {
                        await confirmAndStartWrites()
                    }
                }
                Button(String(localized: "startup.webdav.dryRun.cancel"), role: .cancel) {
                    startupStorageSelectionRaw = StartupStorageSelection.localOnly.rawValue
                }
            } message: {
                Text(dryRunSummaryMessage())
            }
    }

    private var startupStorageSelection: StartupStorageSelection {
        StartupStorageSelection(rawValue: startupStorageSelectionRaw) ?? .iCloud
    }

    private var webDAVMigrationStage: StartupMigrationStage {
        StartupMigrationStage(rawValue: webDAVMigrationStageRaw) ?? .notStarted
    }

    private func runStartupDecisionFlow() async {
        let iCloudStatus = await FileStorageManager.shared.checkICloudAvailabilityNow()

        if iCloudStatus.isAvailable, startupStorageSelection == .iCloud {
            logger.info("iCloud available and selected, proceeding with standard startup sync")
            await enableSyncAndPerformStartupSync()
            return
        }

        if !isWebDAVConfigured {
            logger.info("No WebDAV configuration found, showing fallback chooser")
            showWebDAVFallbackChooser = true
            return
        }

        await runWebDAVDryRunIfNeeded()
    }

    private func runWebDAVDryRunIfNeeded() async {
        await FileStorageManager.shared.enableSync()

        if webDAVMigrationVersion == 1, webDAVMigrationStage == .writesConfirmed {
            logger.info("WebDAV startup migration already confirmed, running startup sync")
            do {
                try await FileStorageManager.shared.performStartupSync()
            } catch {
                logger.error("Startup sync failed after confirmed migration: \(error.localizedDescription)")
            }
            return
        }

        do {
            let report = try await FileStorageManager.shared.performStartupSyncDryRun()
            dryRunReport = report
            webDAVMigrationVersion = 1
            webDAVMigrationStageRaw = StartupMigrationStage.dryRunCompleted.rawValue
            showWebDAVDryRunPrompt = true
        } catch {
            logger.error("WebDAV dry run failed: \(error.localizedDescription)")
        }
    }

    private func confirmAndStartWrites() async {
        webDAVMigrationVersion = 1
        webDAVMigrationStageRaw = StartupMigrationStage.writesConfirmed.rawValue

        do {
            try await FileStorageManager.shared.performStartupSync()
            logger.info("Startup sync completed after explicit confirmation")
        } catch {
            logger.error("Startup sync failed after confirmation: \(error.localizedDescription)")
        }
    }

    private func enableSyncAndPerformStartupSync() async {
        logger.info("Enabling FileStorage sync...")
        await FileStorageManager.shared.enableSync()

        logger.info("Starting DiffScan...")
        do {
            try await FileStorageManager.shared.performStartupSync()
            logger.info("Startup sync completed")
        } catch {
            logger.error("Startup sync failed: \(error.localizedDescription)")
        }
    }

    private func dryRunSummaryMessage() -> String {
        guard let dryRunReport else {
            return String(localized: "startup.webdav.dryRun.message.empty")
        }

        let format = String(localized: "startup.webdav.dryRun.message.format")
        return String(format: format, dryRunReport.downloadCount, dryRunReport.uploadCount, dryRunReport.missingCount)
    }
}

extension View {
    /// Apply StartupSyncModifier to enable file sync after migration
    func startupSync() -> some View {
        modifier(StartupSyncModifier())
    }
}
