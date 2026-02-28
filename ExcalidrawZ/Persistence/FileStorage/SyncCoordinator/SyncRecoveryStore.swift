import Foundation
import CryptoKit
import Logging

struct SyncSnapshotEntry: Codable {
    let fileID: String
    let relativePath: String
    let localHash: String
    let modifiedAt: Date
}

struct SyncRecoveryCheckpointSummary: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let reason: String
    let kind: String
    let fileCount: Int
}

struct SyncOperationJournalEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let action: String
    let fileID: String?
    let relativePath: String?
    let note: String

    init(action: String, fileID: String? = nil, relativePath: String? = nil, note: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.action = action
        self.fileID = fileID
        self.relativePath = relativePath
        self.note = note
    }
}

actor SyncRecoveryStore {
    private let logger = Logger(label: "SyncRecoveryStore")
    private let localManager: LocalStorageManager
    private let maxJournalEntries = 200

    private var baseURL: URL? {
        guard let appSupport = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return nil
        }
        let url = appSupport.appendingPathComponent("FileStorage/Recovery", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var snapshotsURL: URL? { baseURL?.appendingPathComponent("snapshots.json") }
    private var checkpointsURL: URL? { baseURL?.appendingPathComponent("checkpoints.json") }
    private var journalURL: URL? { baseURL?.appendingPathComponent("journal.json") }
    private var checkpointPayloadsDir: URL? {
        guard let baseURL else { return nil }
        let url = baseURL.appendingPathComponent("payloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    init(localManager: LocalStorageManager) {
        self.localManager = localManager
    }

    func ensurePreSyncSnapshotIfNeeded(expectedFiles: [SyncFileState], trigger: String) async {
        guard let snapshotsURL else { return }
        if FileManager.default.fileExists(atPath: snapshotsURL.path) { return }
        await createPreSyncSnapshot(expectedFiles: expectedFiles, trigger: trigger)
    }

    func createPreSyncSnapshot(expectedFiles: [SyncFileState], trigger: String) async {
        var entries: [SyncSnapshotEntry] = []
        for file in expectedFiles {
            guard await localManager.fileExists(relativePath: file.relativePath) else { continue }
            guard let data = try? await localManager.loadContent(relativePath: file.relativePath),
                  let metadata = try? await localManager.getFileMetadata(relativePath: file.relativePath) else { continue }

            let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
            entries.append(
                SyncSnapshotEntry(
                    fileID: file.fileID,
                    relativePath: file.relativePath,
                    localHash: hash,
                    modifiedAt: metadata.modifiedAt
                )
            )
        }

        guard let snapshotsURL,
              let data = try? JSONEncoder.pretty.encode(entries) else { return }

        do {
            try data.write(to: snapshotsURL, options: .atomic)
            await appendCheckpoint(kind: "pre-sync", reason: trigger, files: entries)
            await appendJournal(.init(action: "pre_sync_snapshot", note: "Created with \(entries.count) files"))
        } catch {
            logger.error("Failed to write pre-sync snapshot: \(error.localizedDescription)")
        }
    }

    func createRecoveryCheckpoint(for file: SyncFileState, reason: String) async {
        guard await localManager.fileExists(relativePath: file.relativePath) else { return }
        guard let data = try? await localManager.loadContent(relativePath: file.relativePath),
              let metadata = try? await localManager.getFileMetadata(relativePath: file.relativePath) else { return }
        let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        let entry = SyncSnapshotEntry(fileID: file.fileID, relativePath: file.relativePath, localHash: hash, modifiedAt: metadata.modifiedAt)
        await appendCheckpoint(kind: "risky-op", reason: reason, files: [entry], payloads: [file.relativePath: data])
        await appendJournal(.init(action: "checkpoint", fileID: file.fileID, relativePath: file.relativePath, note: reason))
    }

    func createBulkDeleteCheckpoint(files: [SyncFileState], reason: String) async {
        guard !files.isEmpty else { return }
        var entries: [SyncSnapshotEntry] = []
        var payloads: [String: Data] = [:]

        for file in files {
            guard await localManager.fileExists(relativePath: file.relativePath) else { continue }
            guard let data = try? await localManager.loadContent(relativePath: file.relativePath),
                  let metadata = try? await localManager.getFileMetadata(relativePath: file.relativePath) else { continue }
            let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
            entries.append(.init(fileID: file.fileID, relativePath: file.relativePath, localHash: hash, modifiedAt: metadata.modifiedAt))
            payloads[file.relativePath] = data
        }

        guard !entries.isEmpty else { return }
        await appendCheckpoint(kind: "bulk-delete", reason: reason, files: entries, payloads: payloads)
        await appendJournal(.init(action: "bulk_delete_checkpoint", note: "\(entries.count) files"))
    }

    func appendJournal(_ entry: SyncOperationJournalEntry) async {
        var items = (try? readJSON([SyncOperationJournalEntry].self, from: journalURL)) ?? []
        items.append(entry)
        if items.count > maxJournalEntries {
            items = Array(items.suffix(maxJournalEntries))
        }
        try? writeJSON(items, to: journalURL)
    }

    func listCheckpoints() async -> [SyncRecoveryCheckpointSummary] {
        ((try? readJSON([SyncRecoveryCheckpointSummary].self, from: checkpointsURL)) ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    func listJournal() async -> [SyncOperationJournalEntry] {
        ((try? readJSON([SyncOperationJournalEntry].self, from: journalURL)) ?? []).sorted { $0.timestamp > $1.timestamp }
    }

    func restoreLatestPreSyncSnapshot() async throws -> Int {
        let checkpoints = await listCheckpoints()
        guard let pre = checkpoints.first(where: { $0.kind == "pre-sync" }) else { return 0 }
        return try await restoreCheckpoint(id: pre.id)
    }

    func restoreCheckpoint(id: UUID) async throws -> Int {
        guard let payloadsDir = checkpointPayloadsDir else { return 0 }
        let checkpointDir = payloadsDir.appendingPathComponent(id.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: checkpointDir.path) else { return 0 }

        let files = (try? FileManager.default.contentsOfDirectory(at: checkpointDir, includingPropertiesForKeys: nil)) ?? []
        var restoredCount = 0
        for sourceURL in files where sourceURL.pathExtension == "bin" {
            let relativePath = sourceURL.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? ""
            guard !relativePath.isEmpty else { continue }
            let data = try Data(contentsOf: sourceURL)
            let parsedType = FileStorageContentType.from(relativePath: relativePath) ?? .file
            let fileID = relativePath.components(separatedBy: "/").last?.components(separatedBy: ".").first ?? UUID().uuidString
            _ = try await localManager.saveContent(data, fileID: fileID, type: parsedType, updatedAt: Date())
            restoredCount += 1
        }
        await appendJournal(.init(action: "restore", note: "Restored checkpoint \(id.uuidString.prefix(8)) with \(restoredCount) files"))
        return restoredCount
    }

    private func appendCheckpoint(kind: String, reason: String, files: [SyncSnapshotEntry], payloads: [String: Data] = [:]) async {
        var checkpoints = (try? readJSON([SyncRecoveryCheckpointSummary].self, from: checkpointsURL)) ?? []
        let summary = SyncRecoveryCheckpointSummary(id: UUID(), createdAt: Date(), reason: reason, kind: kind, fileCount: files.count)
        checkpoints.append(summary)
        try? writeJSON(checkpoints, to: checkpointsURL)

        guard let payloadsDir = checkpointPayloadsDir else { return }
        let checkpointDir = payloadsDir.appendingPathComponent(summary.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: checkpointDir, withIntermediateDirectories: true)

        let payloadSource: [String: Data]
        if payloads.isEmpty {
            var collected: [String: Data] = [:]
            for file in files {
                if let data = try? await localManager.loadContent(relativePath: file.relativePath) {
                    collected[file.relativePath] = data
                }
            }
            payloadSource = collected
        } else {
            payloadSource = payloads
        }

        for (relativePath, data) in payloadSource {
            let safeName = relativePath.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? UUID().uuidString
            let fileURL = checkpointDir.appendingPathComponent("\(safeName).bin")
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from url: URL?) throws -> T {
        guard let url else { throw FileStorageError.fileNotFound("json") }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.pretty.decode(T.self, from: data)
    }

    private func writeJSON<T: Encodable>(_ object: T, to url: URL?) throws {
        guard let url else { return }
        let data = try JSONEncoder.pretty.encode(object)
        try data.write(to: url, options: .atomic)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var pretty: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
