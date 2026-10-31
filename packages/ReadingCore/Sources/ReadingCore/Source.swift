import Foundation

public enum SourceError: Error, Equatable {
    case emptySnapshot
    case duplicateID
    case wrongArticle
    case wrongSnapshot
    case unknownBlock
    case unknownSentence
    case invalidRange
    case inconsistentSentenceRange
    case invalidContextLimit
    case contentHashMismatch
}

/// All offsets are UTF-16 code units within the stored block, never characters or UTF-8 bytes.
public struct UTF16Range: Codable, Hashable, Sendable {
    public let location: Int
    public let length: Int
    public init(location: Int, length: Int) { self.location = location; self.length = length }

    public func substring(in text: String) throws -> String {
        guard location >= 0, length > 0, location <= text.utf16.count,
              length <= text.utf16.count - location,
              let range = Range(NSRange(location: location, length: length), in: text)
        else { throw SourceError.invalidRange }
        return String(text[range])
    }

    public func contains(_ other: UTF16Range) -> Bool {
        guard location >= 0, length > 0, other.location >= location, other.length > 0,
              other.location - location <= length else { return false }
        return other.length <= length - (other.location - location)
    }
}

public struct SourceRef: Codable, Hashable, Sendable {
    public let articleID: String
    public let snapshotID: String
    public let blockID: String
    public let sentenceID: String?
    public let rangeUTF16: UTF16Range?
    public init(articleID: String, snapshotID: String, blockID: String,
                sentenceID: String? = nil, rangeUTF16: UTF16Range? = nil) {
        self.articleID = articleID; self.snapshotID = snapshotID; self.blockID = blockID
        self.sentenceID = sentenceID; self.rangeUTF16 = rangeUTF16
    }
}

public struct Article: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public var author: String?
    public var sourceURL: URL?
    public let createdAt: Date
    public init(id: String = UUID().uuidString, title: String, author: String? = nil,
                sourceURL: URL? = nil, createdAt: Date = Date()) {
        self.id = id; self.title = title; self.author = author
        self.sourceURL = sourceURL; self.createdAt = createdAt
    }
}

public enum BlockKind: String, Codable, CaseIterable, Sendable {
    case heading, paragraph, listItem, blockquote, code
}

public struct Sentence: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let rangeUTF16: UTF16Range
    public init(id: String = UUID().uuidString, rangeUTF16: UTF16Range) {
        self.id = id; self.rangeUTF16 = rangeUTF16
    }
}

public struct ArticleBlock: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let kind: BlockKind
    public let text: String
    public let sentences: [Sentence]
    public init(id: String = UUID().uuidString, kind: BlockKind = .paragraph,
                text: String, sentences: [Sentence]) {
        self.id = id; self.kind = kind; self.text = text; self.sentences = sentences
    }
}

/// Imported text cannot be mutated. Reimport and edits create a new snapshot and new references.
public struct ArticleSnapshot: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let articleID: String
    public let blocks: [ArticleBlock]
    public let importedAt: Date
    public let extractorVersion: String
    public let segmenterVersion: String
    public let contentHash: String

    public init(id: String = UUID().uuidString, articleID: String, blocks: [ArticleBlock],
                importedAt: Date = Date(), extractorVersion: String = "paste-v1",
                segmenterVersion: String = "NLTokenizer-v1") throws {
        self.id = id; self.articleID = articleID; self.blocks = blocks; self.importedAt = importedAt
        self.extractorVersion = extractorVersion; self.segmenterVersion = segmenterVersion
        self.contentHash = Self.hash(blocks)
        try validate()
    }

    public func validate() throws {
        guard !id.isEmpty, !articleID.isEmpty, !blocks.isEmpty,
              blocks.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw SourceError.emptySnapshot }
        var ids = Set<String>()
        for block in blocks {
            guard !block.id.isEmpty, ids.insert(block.id).inserted else { throw SourceError.duplicateID }
            var previousEnd = 0
            for sentence in block.sentences {
                guard !sentence.id.isEmpty, ids.insert(sentence.id).inserted else { throw SourceError.duplicateID }
                _ = try sentence.rangeUTF16.substring(in: block.text)
                guard sentence.rangeUTF16.location >= previousEnd else { throw SourceError.invalidRange }
                previousEnd = sentence.rangeUTF16.location + sentence.rangeUTF16.length
            }
        }
        guard contentHash == Self.hash(blocks) else { throw SourceError.contentHashMismatch }
    }

    private static func hash(_ blocks: [ArticleBlock]) -> String {
        // Length-prefix UTF-8 fields so concatenation and line-break ambiguity cannot collide.
        var bytes = [UInt8]()
        for block in blocks {
            for field in [block.kind.rawValue, block.text] {
                let data = Array(field.utf8)
                bytes += Array("\(data.count):".utf8) + data
            }
        }
        return "sha256:" + SHA256.hex(bytes)
    }

    private enum CodingKeys: String, CodingKey {
        case id, articleID, blocks, importedAt, extractorVersion, segmenterVersion, contentHash
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        articleID = try c.decode(String.self, forKey: .articleID)
        blocks = try c.decode([ArticleBlock].self, forKey: .blocks)
        importedAt = try c.decode(Date.self, forKey: .importedAt)
        extractorVersion = try c.decode(String.self, forKey: .extractorVersion)
        segmenterVersion = try c.decode(String.self, forKey: .segmenterVersion)
        contentHash = try c.decode(String.self, forKey: .contentHash)
        try validate()
    }
}

public struct ResolvedSource: Hashable, Sendable {
    public let ref: SourceRef
    public let text: String
}

public struct SourceResolver: Sendable {
    public let snapshot: ArticleSnapshot
    public init(snapshot: ArticleSnapshot) { self.snapshot = snapshot }

    public var allSentenceRefs: [SourceRef] {
        snapshot.blocks.flatMap { block in block.sentences.map { sentence in
            SourceRef(articleID: snapshot.articleID, snapshotID: snapshot.id,
                      blockID: block.id, sentenceID: sentence.id, rangeUTF16: sentence.rangeUTF16)
        } }
    }

    public func resolve(_ ref: SourceRef) throws -> ResolvedSource {
        guard ref.articleID == snapshot.articleID else { throw SourceError.wrongArticle }
        guard ref.snapshotID == snapshot.id else { throw SourceError.wrongSnapshot }
        guard let block = snapshot.blocks.first(where: { $0.id == ref.blockID }) else { throw SourceError.unknownBlock }
        let range: UTF16Range
        if let sentenceID = ref.sentenceID {
            guard let sentence = block.sentences.first(where: { $0.id == sentenceID }) else { throw SourceError.unknownSentence }
            if let requested = ref.rangeUTF16 {
                guard sentence.rangeUTF16.contains(requested) else { throw SourceError.inconsistentSentenceRange }
                range = requested
            } else { range = sentence.rangeUTF16 }
        } else { range = ref.rangeUTF16 ?? UTF16Range(location: 0, length: block.text.utf16.count) }
        return ResolvedSource(ref: ref, text: try range.substring(in: block.text))
    }

    /// Canonical identity for persistence and deduplication when optional ranges were omitted by a caller.
    public func canonicalRef(_ ref: SourceRef) throws -> SourceRef {
        _ = try resolve(ref)
        let block = snapshot.blocks.first { $0.id == ref.blockID }!
        let range = ref.rangeUTF16
            ?? block.sentences.first(where: { $0.id == ref.sentenceID })?.rangeUTF16
            ?? UTF16Range(location: 0, length: block.text.utf16.count)
        return SourceRef(articleID: ref.articleID, snapshotID: ref.snapshotID, blockID: ref.blockID,
                         sentenceID: ref.sentenceID, rangeUTF16: range)
    }

    public func context(around ref: SourceRef, before: Int = 1, after: Int = 1) throws -> [ResolvedSource] {
        _ = try resolve(ref)
        guard (0...10).contains(before), (0...10).contains(after) else { throw SourceError.invalidContextLimit }
        let refs = allSentenceRefs
        guard let index = refs.firstIndex(where: { $0.blockID == ref.blockID && $0.sentenceID == ref.sentenceID })
        else { return [try resolve(ref)] }
        return try refs[max(0, index - before)...min(refs.count - 1, index + after)].map(resolve)
    }

    /// Maps AVSpeechSynthesizer's utterance-relative range back to the immutable block.
    public func playbackRange(_ utteranceRange: UTF16Range, for ref: SourceRef) throws -> SourceRef {
        let resolved = try resolve(ref)
        _ = try utteranceRange.substring(in: resolved.text)
        let block = snapshot.blocks.first { $0.id == ref.blockID }!
        let start = ref.rangeUTF16?.location
            ?? block.sentences.first(where: { $0.id == ref.sentenceID })?.rangeUTF16.location ?? 0
        let mapped = SourceRef(articleID: ref.articleID, snapshotID: ref.snapshotID, blockID: ref.blockID,
                               sentenceID: ref.sentenceID,
                               rangeUTF16: UTF16Range(location: start + utteranceRange.location, length: utteranceRange.length))
        _ = try resolve(mapped)
        return mapped
    }
}
