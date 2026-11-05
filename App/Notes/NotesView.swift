import SwiftUI
import YuvomiKit

struct NotesView: View {
    @State private var model: NotesModel
    @State private var creating = false
    @Environment(\.scenePhase) private var scenePhase

    init(client: YuvomiClient) {
        _model = State(initialValue: NotesModel(client: client))
    }

    private struct Route: Hashable { let id: Int }

    var body: some View {
        List {
            section("Épinglées", model.pinned)
            section(model.pinned.isEmpty ? nil : "Autres", model.others)
        }
        .overlay {
            if model.visible.isEmpty {
                if model.isLoading && model.notes.isEmpty {
                    ProgressView()
                } else if !model.search.isEmpty {
                    ContentUnavailableView.search(text: model.search)
                } else {
                    ContentUnavailableView("Aucune note", systemImage: "note.text",
                                           description: Text("Ajoutez-en une avec +."))
                }
            }
        }
        .searchable(text: $model.search, prompt: "Rechercher dans les notes")
        .navigationTitle("Notes")
        .navigationDestination(for: Route.self) { NoteDetailView(model: model, noteID: $0.id) }
        .toolbar {
            #if os(macOS)
            ToolbarItem {
                Button("Actualiser", systemImage: "arrow.clockwise") { Task { await model.load() } }
                    .keyboardShortcut("r")
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Button("Nouvelle note", systemImage: "square.and.pencil") { creating = true }
                    .keyboardShortcut("n")
            }
        }
        .sheet(isPresented: $creating) {
            NavigationStack { NoteEditorView(model: model, note: nil) }
                #if os(macOS)
                .frame(minWidth: 480, minHeight: 440)
                #endif
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.load() } }
        }
        .alert("Notes", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func section(_ title: String?, _ notes: [Note]) -> some View {
        if !notes.isEmpty {
            Section {
                ForEach(notes) { note in
                    NavigationLink(value: Route(id: note.id)) { NoteRow(note: note) }
                        .swipeActions(edge: .leading) {
                            Button(note.isPinned ? "Désépingler" : "Épingler",
                                   systemImage: note.isPinned ? "pin.slash" : "pin") {
                                Task { await model.togglePin(note) }
                            }
                            .tint(.orange)
                        }
                        .swipeActions(edge: .trailing) {
                            if !note.isLocked {
                                Button("Supprimer", systemImage: "trash", role: .destructive) {
                                    Task { _ = await model.delete(note) }
                                }
                            }
                        }
                        .contextMenu {
                            Button(note.isPinned ? "Désépingler" : "Épingler", systemImage: "pin") {
                                Task { await model.togglePin(note) }
                            }
                            if !note.isLocked {
                                Button("Supprimer", systemImage: "trash", role: .destructive) {
                                    Task { _ = await model.delete(note) }
                                }
                            }
                        }
                }
            } header: {
                if let title { Text(title) }
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}

private struct NoteRow: View {
    let note: Note

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(NoteColor.color(note.color))
                .frame(width: 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(note.title?.isEmpty == false ? note.title! : note.preview)
                        .font(.body.weight(.medium)).lineLimit(1)
                    if note.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                    if note.isLocked { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts: [String] = []
        if note.title?.isEmpty == false, !note.preview.isEmpty { parts.append(note.preview) }
        if let progress = note.checklistProgress { parts.append("\(progress.done)/\(progress.total) cochées") }
        if let date = note.updatedAt { parts.append(date.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }
}

/// The web app's sticky-note palette.
enum NoteColor {
    static let palette: [(name: String, hex: String)] = [
        ("Jaune", "#FFEB3B"), ("Orange", "#FFB74D"), ("Rose", "#F48FB1"), ("Violet", "#CE93D8"),
        ("Bleu", "#90CAF9"), ("Vert", "#A5D6A7"), ("Gris", "#E0E0E0"),
    ]

    static func color(_ hex: String?) -> Color { Color(hex: hex) ?? Color(hex: "#FFEB3B")! }
}
