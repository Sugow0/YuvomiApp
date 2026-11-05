import Foundation
import Observation
import YuvomiKit

@MainActor @Observable
final class NotesModel {
    let client: YuvomiClient

    private(set) var notes: [Note] = []
    private(set) var isLoading = false
    var search = ""
    var errorMessage: String?

    init(client: YuvomiClient) { self.client = client }

    var visible: [Note] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return notes }
        return notes.filter {
            ($0.title?.localizedStandardContains(query) ?? false) || $0.content.localizedStandardContains(query)
        }
    }
    var pinned: [Note] { visible.filter(\.isPinned) }
    var others: [Note] { visible.filter { !$0.isPinned } }

    func note(_ id: Int) -> Note? { notes.first { $0.id == id } }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            notes = try await client.notes()
        } catch {
            errorMessage = error.userMessage
        }
    }

    /// Returns the saved note, or nil with `errorMessage` set.
    func save(id: Int?, title: String, content: String, color: String?) async -> Note? {
        do {
            if let id {
                let saved = try await client.updateNote(id, title: title, content: content, color: color)
                replace(saved)
                return saved
            }
            let created = try await client.createNote(title: title, content: content, color: color)
            notes.insert(created, at: notes.firstIndex { !$0.isPinned } ?? notes.endIndex)
            return created
        } catch {
            errorMessage = error.userMessage
            return nil
        }
    }

    func togglePin(_ note: Note) async {
        update(note.id) { $0.isPinned.toggle() }
        do {
            let pinned = try await client.toggleNotePin(note.id)
            update(note.id) { $0.isPinned = pinned }
            resort()
        } catch {
            update(note.id) { $0.isPinned = note.isPinned }
            errorMessage = error.userMessage
        }
    }

    func check(_ note: Note, _ item: NoteBlock.ChecklistItem) async {
        // Optimistic: flip the box in the text, the server answers with the real state.
        let lines = NoteBlock.lines(note.content)
        if item.line < lines.count {
            var edited = lines
            edited[item.line] = item.raw.replacing(/\[[ xX]\]/, maxReplacements: 1) { _ in item.checked ? "[ ]" : "[x]" }
            update(note.id) { $0.content = edited.joined(separator: "\n") }
        }
        do {
            replace(try await client.checkNoteItem(note.id, item, checked: !item.checked))
        } catch let error as APIError where error.code == 409 {
            errorMessage = "La note a changé entre-temps. Elle a été rechargée."
            await load()
        } catch {
            update(note.id) { $0.content = note.content }
            errorMessage = error.userMessage
        }
    }

    func delete(_ note: Note) async -> Bool {
        let backup = notes
        notes.removeAll { $0.id == note.id }
        do {
            try await client.deleteNote(note.id)
            return true
        } catch {
            notes = backup
            errorMessage = error.userMessage
            return false
        }
    }

    private func replace(_ note: Note) {
        update(note.id) { $0 = note }
    }

    private func resort() {
        notes = notes.filter(\.isPinned) + notes.filter { !$0.isPinned }
    }

    private func update(_ id: Int, _ change: (inout Note) -> Void) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        change(&notes[index])
    }
}
