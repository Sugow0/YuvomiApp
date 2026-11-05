import Foundation

// MARK: - Model (server/routes/notes.js)

public struct Note: Sendable, Hashable, Identifiable, Decodable {
    public let id: Int
    public var title: String?
    public var content: String
    /// `#RRGGBB`; the web app's default is a sticky-note yellow.
    public var color: String?
    public var isPinned: Bool
    public let isLocked: Bool
    public let creatorName: String?
    public let updatedAt: Date?

    enum CodingKeys: String, CodingKey { case id, title, content, color, pinned, locked, creatorName, updatedAt }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        color = try? c.decodeIfPresent(String.self, forKey: .color)
        isPinned = ((try? c.decode(Int.self, forKey: .pinned)) ?? 0) != 0 || ((try? c.decode(Bool.self, forKey: .pinned)) ?? false)
        isLocked = ((try? c.decode(Int.self, forKey: .locked)) ?? 0) != 0
        creatorName = try? c.decodeIfPresent(String.self, forKey: .creatorName)
        updatedAt = (try? c.decodeIfPresent(String.self, forKey: .updatedAt)).flatMap { Reminder.parse($0) }
    }

    public init(id: Int, title: String? = nil, content: String, color: String? = nil, isPinned: Bool = false) {
        self.id = id; self.title = title; self.content = content; self.color = color; self.isPinned = isPinned
        isLocked = false; creatorName = nil; updatedAt = nil
    }

    public var blocks: [NoteBlock] { NoteBlock.parse(content) }

    /// First non-empty line without Markdown marks, for a list row.
    public var preview: String {
        for block in blocks {
            switch block {
            case let .text(text):
                let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                let clean = line.trimmingCharacters(in: CharacterSet(charactersIn: "#>*_ ").union(.whitespaces))
                if !clean.isEmpty { return clean }
            case let .checklist(item):
                return (item.checked ? "☑︎ " : "☐ ") + item.text
            }
        }
        return ""
    }

    public var checklistProgress: (done: Int, total: Int)? {
        let items = blocks.compactMap { if case let .checklist(item) = $0 { item } else { nil } }
        return items.isEmpty ? nil : (items.filter(\.checked).count, items.count)
    }
}

/// A note's body as the web renderer reads it: checklist lines are interactive, the rest is text.
public enum NoteBlock: Sendable, Hashable {
    public struct ChecklistItem: Sendable, Hashable {
        /// Zero-based line in the note, as `PATCH /notes/:id/check` counts it.
        public let line: Int
        public let checked: Bool
        public let text: String
        /// The raw line, sent as `expect` so a concurrent edit answers 409, not a wrong tick.
        public let raw: String
    }

    case text(String)
    case checklist(ChecklistItem)

    /// Same rule as public/utils/markdown-checklist.js: up to 3 spaces, `-`/`*`/`+`, `[ ]`/`[x]`, text.
    nonisolated(unsafe) private static let pattern = /^ {0,3}[-*+]\s+\[([ xX])\]\s+(.*)$/

    public static func lines(_ content: String) -> [String] {
        content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    public static func parse(_ content: String) -> [NoteBlock] {
        var blocks: [NoteBlock] = []
        var paragraph: [String] = []
        func flush() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { blocks.append(.text(text)) }
            paragraph = []
        }
        for (index, line) in lines(content).enumerated() {
            if let match = line.wholeMatch(of: pattern) {
                flush()
                blocks.append(.checklist(ChecklistItem(line: index, checked: match.1 != " ",
                                                       text: String(match.2), raw: line)))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }
}

// MARK: - Endpoints

extension YuvomiClient {
    /// Pinned first, then most recently changed.
    public func notes() async throws -> [Note] {
        try await http.send("GET", "api/v1/notes", as: DataEnvelope<[Note]>.self).data
    }

    public func createNote(title: String?, content: String, color: String?) async throws -> Note {
        struct Body: Encodable, Sendable { let title: String?; let content: String; let color: String? }
        return try await http.send(
            "POST", "api/v1/notes", body: Body(title: Self.blankToNil(title), content: content, color: color),
            headers: ["Idempotency-Key": UUID().uuidString],
            as: DataEnvelope<Note>.self
        ).data
    }

    public func updateNote(_ id: Int, title: String?, content: String, color: String?) async throws -> Note {
        struct Body: Encodable, Sendable {
            let title: String?; let content: String; let color: String?
            enum CodingKeys: String, CodingKey { case title, content, color }
            func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(title, forKey: .title) // null clears the title
                try c.encode(content, forKey: .content)
                try c.encodeIfPresent(color, forKey: .color)
            }
        }
        return try await http.send(
            "PUT", "api/v1/notes/\(id)", body: Body(title: Self.blankToNil(title), content: content, color: color),
            as: DataEnvelope<Note>.self
        ).data
    }

    /// The server toggles; answers the new state.
    public func toggleNotePin(_ id: Int) async throws -> Bool {
        struct Pin: Decodable { let pinned: Int }
        return try await http.send("PATCH", "api/v1/notes/\(id)/pin", as: DataEnvelope<Pin>.self).data.pinned != 0
    }

    /// Ticks one checklist line without rewriting the rest (two people can tick at once).
    public func checkNoteItem(_ noteID: Int, _ item: NoteBlock.ChecklistItem, checked: Bool) async throws -> Note {
        struct Body: Encodable, Sendable { let line: Int; let checked: Bool; let expect: String }
        return try await http.send(
            "PATCH", "api/v1/notes/\(noteID)/check", body: Body(line: item.line, checked: checked, expect: item.raw),
            as: DataEnvelope<Note>.self
        ).data
    }

    public func deleteNote(_ id: Int) async throws {
        _ = try await http.send("DELETE", "api/v1/notes/\(id)", as: Empty.self)
    }

    private static func blankToNil(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
