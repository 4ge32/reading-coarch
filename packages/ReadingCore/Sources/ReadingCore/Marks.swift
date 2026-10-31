import Foundation

public struct Mark: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let sourceRef: SourceRef
    public let createdAt: Date
    public var active: Bool
    public var note: String?
    public init(id: String = UUID().uuidString, sourceRef: SourceRef, createdAt: Date = Date(),
                active: Bool = true, note: String? = nil) {
        self.id = id; self.sourceRef = sourceRef; self.createdAt = createdAt
        self.active = active; self.note = note
    }
}

/// Pure local state. Toggling never starts a run, issues a network request, or removes history.
public struct MarkStore: Codable, Sendable {
    public private(set) var marks: [Mark]
    public let snapshot: ArticleSnapshot
    public init(snapshot: ArticleSnapshot, marks: [Mark] = []) {
        self.snapshot = snapshot; self.marks = marks
    }
    public var activeMarks: [Mark] {
        let resolver = SourceResolver(snapshot: snapshot)
        let order = resolver.allSentenceRefs
        return marks.filter { $0.active && (try? resolver.resolve($0.sourceRef)) != nil }.sorted { a, b in
            let ai = order.firstIndex { $0.sentenceID == a.sourceRef.sentenceID && $0.blockID == a.sourceRef.blockID } ?? .max
            let bi = order.firstIndex { $0.sentenceID == b.sourceRef.sentenceID && $0.blockID == b.sourceRef.blockID } ?? .max
            return ai == bi ? a.createdAt < b.createdAt : ai < bi
        }
    }
    @discardableResult
    public mutating func toggle(_ ref: SourceRef, at: Date = Date()) throws -> Mark {
        let resolver = SourceResolver(snapshot: snapshot)
        let canonical = try resolver.canonicalRef(ref)
        if let index = marks.firstIndex(where: { (try? resolver.canonicalRef($0.sourceRef)) == canonical }) {
            marks[index].active.toggle()
            return marks[index]
        }
        let mark = Mark(sourceRef: canonical, createdAt: at)
        marks.append(mark)
        return mark
    }
    @discardableResult
    public mutating func markUnclear(_ ref: SourceRef, at: Date = Date()) throws -> Mark {
        let resolver = SourceResolver(snapshot: snapshot)
        let canonical = try resolver.canonicalRef(ref)
        if let index = marks.firstIndex(where: { (try? resolver.canonicalRef($0.sourceRef)) == canonical }) {
            marks[index].active = true
            return marks[index]
        }
        let mark = Mark(sourceRef: canonical, createdAt: at)
        marks.append(mark)
        return mark
    }

    private enum CodingKeys: String, CodingKey { case marks, snapshot }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = try c.decode(ArticleSnapshot.self, forKey: .snapshot)
        marks = try c.decode([Mark].self, forKey: .marks)
        let resolver = SourceResolver(snapshot: snapshot)
        let refs = try marks.map { try resolver.canonicalRef($0.sourceRef) }
        guard Set(marks.map(\.id)).count == marks.count, Set(refs).count == refs.count
        else { throw SourceError.duplicateID }
    }
}
