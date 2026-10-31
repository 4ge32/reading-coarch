import Foundation
import NaturalLanguage
import ReadingCore

enum ArticleImporter {
    static func snapshot(articleID: String = UUID().uuidString, blocks: [(BlockKind, String)], extractorVersion: String = "paste-v1") throws -> ArticleSnapshot {
        let imported = blocks.filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { kind, text in
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = text
            tokenizer.setLanguage(.english)
            var sentences: [Sentence] = []
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                let nsRange = NSRange(range, in: text)
                sentences.append(Sentence(rangeUTF16: UTF16Range(location: nsRange.location, length: nsRange.length)))
                return true
            }
            return ArticleBlock(kind: kind, text: text, sentences: sentences)
        }
        return try ArticleSnapshot(articleID: articleID, blocks: imported, extractorVersion: extractorVersion)
    }

    static func pastedBlocks(_ text: String) -> [(BlockKind, String)] {
        text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { (.paragraph, $0) }
    }

    static func warnings(for blocks: [(BlockKind, String)]) -> [String] {
        let text = blocks.map(\.1).joined(separator: "\n")
        var warnings: [String] = []
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { warnings.append("本文未取得です。Safariでページを共有し直すか、本文を貼り付けてください。") }
        else if text.count < 80 { warnings.append("本文が短いため、抜けがないか確認してください。") }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if !text.isEmpty && recognizer.dominantLanguage != .english { warnings.append("英語以外の本文の可能性があります。取り込み内容を確認してください。") }
        if !blocks.isEmpty && blocks.filter({ $0.0 == .code }).count * 2 >= blocks.count { warnings.append("コードを多く含みます。文の分割と読み上げを確認してください。") }
        return warnings
    }

    /// Core's unicode-letters-apostrophe-hyphen-v1; code is excluded.
    static func wordCount(_ snapshot: ArticleSnapshot) -> Int {
        return snapshot.blocks.filter { $0.kind != .code }.reduce(0) { result, block in
            result + ReadingTimer.wordCount(block.text)
        }
    }
}
