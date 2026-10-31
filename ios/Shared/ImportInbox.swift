import Foundation

/// The only shared state between the extension and the app. The extension never opens SwiftData.
struct ImportedBlock: Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case heading, paragraph, listItem, blockquote, code
    }
    let kind: Kind
    let text: String
}

struct ImportJob: Codable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable { case extracted, urlOnly }
    let id: UUID
    let createdAt: Date
    let title: String
    let author: String?
    let sourceURL: URL?
    let blocks: [ImportedBlock]
    let extractionVersion: String
    let status: Status

    init(id: UUID = UUID(), createdAt: Date = Date(), title: String, author: String? = nil,
         sourceURL: URL? = nil, blocks: [ImportedBlock],
         extractionVersion: String = "readability-0.6.0/readingcoach-blocks-1", status: Status) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.author = author
        self.sourceURL = sourceURL
        self.blocks = blocks
        self.extractionVersion = extractionVersion
        self.status = status
    }

    func validate() throws {
        guard title.utf8.count <= 16_384, blocks.count <= 2_000,
              blocks.reduce(0, { $0 + $1.text.utf8.count }) <= 4_000_000,
              blocks.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              (status == .urlOnly ? blocks.isEmpty && sourceURL != nil : !blocks.isEmpty) else {
            throw ImportInboxError.invalidJob
        }
        if let sourceURL {
            guard ["https", "http"].contains(sourceURL.scheme?.lowercased() ?? ""),
                  sourceURL.host != nil, sourceURL.user == nil, sourceURL.password == nil else {
                throw ImportInboxError.invalidJob
            }
        }
    }
}

enum ImportInboxError: LocalizedError {
    case unavailableAppGroup, invalidJob, oversizedJob, duplicateJob
    var errorDescription: String? {
        switch self {
        case .unavailableAppGroup: return "共有保存先にアクセスできません。App Groupの署名設定を確認してください。"
        case .invalidJob: return "取り込みデータを読み取れません。入力は削除していません。"
        case .oversizedJob: return "記事が大きすぎます。必要な本文を貼り付けて取り込んでください。"
        case .duplicateJob: return "この共有データは既に保存されています。"
        }
    }
}

struct ImportInboxLoadResult {
    let jobs: [ImportJob]
    /// Corrupt/unreadable jobs stay on disk for retry or explicit user deletion.
    let unreadableFileCount: Int
}

struct ImportInbox {
    static var appGroupIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "ReadingCoachAppGroupIdentifier") as? String
            ?? "group.com.example.ReadingCoach"
    }

    let directory: URL

    init(directory: URL) { self.directory = directory }

    static func shared() throws -> ImportInbox {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw ImportInboxError.unavailableAppGroup
        }
        return ImportInbox(directory: container.appendingPathComponent("ImportInbox", isDirectory: true))
    }

    func write(_ job: ImportJob) throws {
        try job.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(for: job.id)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw ImportInboxError.duplicateJob }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(job)
        guard data.count <= 5_000_000 else { throw ImportInboxError.oversizedJob }
        // Foundation writes a temporary file, then atomically renames it inside the same directory.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func loadPending() throws -> ImportInboxLoadResult {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return ImportInboxLoadResult(jobs: [], unreadableFileCount: 0)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var jobs: [ImportJob] = []
        var failures = 0
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) where url.pathExtension == "json" {
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 5_000_000 else { throw ImportInboxError.oversizedJob }
                let job = try decoder.decode(ImportJob.self, from: Data(contentsOf: url))
                guard url.deletingPathExtension().lastPathComponent == job.id.uuidString else { throw ImportInboxError.invalidJob }
                try job.validate()
                jobs.append(job)
            } catch { failures += 1 }
        }
        return ImportInboxLoadResult(jobs: jobs.sorted { $0.createdAt < $1.createdAt }, unreadableFileCount: failures)
    }

    /// Call only after the database transaction succeeds, or after an explicit discard.
    func acknowledge(_ jobID: UUID) throws {
        let url = fileURL(for: jobID)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func removeAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private func fileURL(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
}
