import ReadingCore
import SwiftUI

struct ImportPreviewView: View {
    @EnvironmentObject private var store: ReadingStore
    @Environment(\.dismiss) private var dismiss
    let job: ImportJob?
    @State private var title = ""
    @State private var text = ""
    @State private var previewing = false
    @State private var errorMessage: String?
    private var blocks: [(BlockKind, String)] {
        if let job { return job.blocks.map { (BlockKind(rawValue: $0.kind.rawValue) ?? .paragraph, $0.text) } }
        return ArticleImporter.pastedBlocks(text)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("タイトル") { TextField("記事のタイトル", text: $title) }
                if job == nil && !previewing {
                    Section("本文を貼り付け") { TextEditor(text: $text).frame(minHeight: 230).accessibilityLabel("貼り付け本文") }
                } else {
                    Section("取り込みプレビュー") {
                        if let url = job?.sourceURL { Text(url.absoluteString).font(.caption).textSelection(.enabled) }
                        Text("保存後の原文は、この取り込み結果のスナップショットです。ページ全体との完全一致は保証しません。").font(.caption)
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            Text(block.1).font(block.0 == .heading ? .headline : .body).textSelection(.enabled)
                        }
                    }
                }
                ForEach(ArticleImporter.warnings(for: blocks), id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                if job == nil && !previewing {
                    Button("プレビュー") { previewing = true }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else if blocks.isEmpty, let job {
                    Button("URLだけ保存（本文未取得）") { saveURL(job) }
                } else {
                    Button("この内容を原文として保存") { save() }.accessibilityIdentifier("confirmImport")
                    if job == nil { Button("編集へ戻る") { previewing = false } }
                }
                if let job { Button("この取り込みを破棄", role: .destructive) { store.discardImport(job); dismiss() } }
            }
            .navigationTitle("取り込み")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .onAppear { title = job?.title ?? "" }
        }
    }
    private func save() {
        do {
            try store.add(title: title, sourceURL: job?.sourceURL, author: job?.author, blocks: blocks, extractionVersion: job?.extractionVersion ?? "paste-v1", importJobID: job?.id)
            if let job { try ImportInbox.shared().acknowledge(job.id); store.refreshInbox() }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
    private func saveURL(_ job: ImportJob) {
        do { try store.saveURLOnly(job); dismiss() } catch { errorMessage = error.localizedDescription }
    }
}
