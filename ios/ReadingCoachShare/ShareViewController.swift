import UIKit
import UniformTypeIdentifiers

/// Shares are saved to an App Group inbox, then previewed and confirmed in the main app.
@MainActor
final class ShareViewController: UIViewController {
    private let message = UILabel()
    private let saveButton = UIButton(type: .system)
    private var pendingJob: ImportJob?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel()
        title.text = "ReadingCoachに取り込む"
        title.font = .preferredFont(forTextStyle: .title2)
        title.adjustsFontForContentSizeCategory = true
        message.numberOfLines = 0
        message.font = .preferredFont(forTextStyle: .body)
        message.adjustsFontForContentSizeCategory = true
        message.text = "本文を確認しています…"
        saveButton.setTitle("保存して閉じる", for: .normal)
        saveButton.isEnabled = false
        saveButton.addTarget(self, action: #selector(save), for: .touchUpInside)
        let cancel = UIButton(type: .system)
        cancel.setTitle("キャンセル", for: .normal)
        cancel.addTarget(self, action: #selector(close), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [title, message, saveButton, cancel])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24)
        ])
        Task { await loadSharedPage() }
    }

    private func loadSharedPage() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) {
            do {
                let result = try await load(provider, identifier: UTType.propertyList.identifier)
                if let propertyList = result as? [String: Any],
                   let payload = propertyList[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any],
                   let job = job(from: payload) {
                    show(job)
                    return
                }
            } catch { /* A URL provider can still make this share useful. */ }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            do {
                let result = try await load(provider, identifier: UTType.url.identifier)
                let url = result as? URL ?? (result as? String).flatMap(URL.init(string:))
                if let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil {
                    show(ImportJob(title: url.host ?? "Shared page", sourceURL: url, blocks: [], status: .urlOnly))
                    return
                }
            } catch { continue }
        }
        message.text = "本文もURLも取得できませんでした。Safariで記事を開いて共有し直すか、本文をアプリへ貼り付けてください。"
    }

    private func load(_ provider: NSItemProvider, identifier: String) async throws -> NSSecureCoding? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: item) }
            }
        }
    }

    private func job(from payload: [String: Any]) -> ImportJob? {
        guard let rawBlocks = payload["blocks"] as? [[String: Any]], rawBlocks.count <= 2_000 else { return nil }
        var blocks: [ImportedBlock] = []
        for raw in rawBlocks {
            guard let rawKind = raw["kind"] as? String, let kind = ImportedBlock.Kind(rawValue: rawKind),
                  let text = raw["text"] as? String else { return nil }
            blocks.append(ImportedBlock(kind: kind, text: text))
        }
        let job = ImportJob(title: payload["title"] as? String ?? "Shared page", author: payload["author"] as? String,
                            sourceURL: (payload["sourceURL"] as? String).flatMap(URL.init(string:)), blocks: blocks,
                            extractionVersion: payload["extractionVersion"] as? String ?? "unknown",
                            status: blocks.isEmpty ? .urlOnly : .extracted)
        do { try job.validate(); return job }
        catch { return nil }
    }

    private func show(_ job: ImportJob) {
        pendingJob = job
        saveButton.isEnabled = true
        if job.status == .urlOnly {
            message.text = "本文未取得：URLのみ保存します。\n\(job.title)\n\nReadingCoachで本文を貼り付けるか、Safariで記事を開いて共有し直してください。"
        } else {
            message.text = "\(job.title)\n\n本文 \(job.blocks.count) ブロックを保存します。ReadingCoachを開き、取り込みプレビューで欠落を確認して確定してください。"
        }
    }

    @objc private func save() {
        guard let job = pendingJob else { return }
        do {
            try ImportInbox.shared().write(job)
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            // Never claim success or discard the source on an App Group/write failure.
            message.text = error.localizedDescription
            saveButton.setTitle("再試行", for: .normal)
        }
    }

    @objc private func close() { extensionContext?.completeRequest(returningItems: nil) }
}
