import SwiftUI
import YuvomiKit

/// Reads a note like the web app renders it: Markdown text, tappable checklist boxes.
struct NoteDetailView: View {
    let model: NotesModel
    let noteID: Int
    @State private var editing = false
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let note = model.note(noteID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let title = note.title, !title.isEmpty {
                        Text(title).font(.title2.weight(.semibold))
                    }
                    ForEach(Array(note.blocks.enumerated()), id: \.offset) { _, block in
                        switch block {
                        case let .text(text):
                            MarkdownText(text)
                        case let .checklist(item):
                            Button { Task { await model.check(note, item) } } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Image(systemName: item.checked ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(item.checked ? Color.accentColor : .secondary)
                                    Text(inline(item.text))
                                        .strikethrough(item.checked)
                                        .foregroundStyle(item.checked ? .secondary : .primary)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .disabled(note.isLocked)
                            .sensoryFeedback(.selection, trigger: item.checked)
                        }
                    }
                    footer(note)
                }
                .padding()
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .clearsTabBar()
            .background(NoteColor.color(note.color).opacity(0.12))
            .navigationTitle(note.title?.isEmpty == false ? note.title! : "Note")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(note.isPinned ? "Désépingler" : "Épingler",
                           systemImage: note.isPinned ? "pin.slash" : "pin") {
                        Task { await model.togglePin(note) }
                    }
                    if !note.isLocked {
                        Button("Modifier") { editing = true }
                            .keyboardShortcut("e")
                    }
                }
                if !note.isLocked {
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Supprimer", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .sheet(isPresented: $editing) {
                NavigationStack { NoteEditorView(model: model, note: note) }
                    #if os(macOS)
                    .frame(minWidth: 480, minHeight: 440)
                    #endif
            }
            .confirmationDialog("Supprimer cette note ?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) {
                    Task { if await model.delete(note) { dismiss() } }
                }
            }
        } else {
            ContentUnavailableView("Note introuvable", systemImage: "note.text")
        }
    }

    private func footer(_ note: Note) -> some View {
        var parts: [String] = []
        if let name = note.creatorName { parts.append("Par \(name)") }
        if let date = note.updatedAt { parts.append("modifiée \(date.formatted(.relative(presentation: .named)))") }
        if note.isLocked { parts.append("verrouillée") }
        return Text(parts.joined(separator: " · "))
            .font(.caption).foregroundStyle(.secondary)
            .padding(.top, 8)
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Paragraphs with inline Markdown, `#` headings and `-` bullets — what notes usually hold.
private struct MarkdownText: View {
    let lines: [String]

    init(_ text: String) { lines = text.components(separatedBy: "\n") }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                row(line)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func row(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer().frame(height: 4)
        } else if let heading = trimmed.wholeMatch(of: /(#{1,6})\s+(.*)/) {
            Text(inline(String(heading.2)))
                .font(heading.1.count == 1 ? .title3.weight(.bold) : .headline)
                .padding(.top, 4)
        } else if let bullet = trimmed.wholeMatch(of: /[-*+]\s+(.*)/) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(String(bullet.1)))
            }
        } else {
            Text(inline(trimmed))
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

struct NoteEditorView: View {
    let model: NotesModel
    let note: Note?
    @State private var title: String
    @State private var content: String
    @State private var color: String
    @State private var saving = false
    @FocusState private var contentFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: NotesModel, note: Note?) {
        self.model = model
        self.note = note
        _title = State(initialValue: note?.title ?? "")
        _content = State(initialValue: note?.content ?? "")
        _color = State(initialValue: note?.color ?? NoteColor.palette[0].hex)
    }

    var body: some View {
        Form {
            Section {
                TextField("Titre (facultatif)", text: $title).font(.headline)
                TextEditor(text: $content)
                    .focused($contentFocused)
                    .frame(minHeight: 220)
                    .font(.body)
            } footer: {
                Text("« - [ ] » au début d'une ligne crée une case à cocher. Markdown simple accepté : **gras**, # titre.")
            }
            Section("Couleur") {
                HStack(spacing: 12) {
                    ForEach(NoteColor.palette, id: \.hex) { swatch in
                        Button { color = swatch.hex } label: {
                            Circle().fill(NoteColor.color(swatch.hex))
                                .frame(width: 28, height: 28)
                                .overlay {
                                    if color.caseInsensitiveCompare(swatch.hex) == .orderedSame {
                                        Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.black.opacity(0.7))
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(swatch.name)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(note == nil ? "Nouvelle note" : "Modifier la note")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(note == nil ? "Ajouter" : "Enregistrer") {
                    Task {
                        saving = true
                        let saved = await model.save(id: note?.id, title: title, content: content, color: color)
                        saving = false
                        if saved != nil { dismiss() }
                    }
                }
                .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                .keyboardShortcut(.return, modifiers: .command)
            }
            ToolbarItem(placement: .automatic) {
                Button("Case à cocher", systemImage: "checklist") { addCheckbox() }
            }
        }
        .task { if note == nil { contentFocused = true } }
    }

    private func addCheckbox() {
        if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
        content += "- [ ] "
        contentFocused = true
    }
}
