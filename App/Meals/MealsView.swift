import SwiftUI
import YuvomiKit

struct MealsView: View {
    @State private var model: MealsModel
    @State private var newMealDay: NewMealDay?
    @Environment(\.scenePhase) private var scenePhase

    init(client: YuvomiClient) {
        _model = State(initialValue: MealsModel(client: client))
    }

    private struct Route: Hashable { let id: Int }
    struct NewMealDay: Identifiable { let day: String; var id: String { day } }

    var body: some View {
        List {
            if let week = model.week {
                ForEach(week.days, id: \.self) { day in
                    Section {
                        ForEach(week.meals(on: day)) { meal in
                            NavigationLink(value: Route(id: meal.id)) { MealRow(meal: meal) }
                                .swipeActions {
                                    Button("Supprimer", systemImage: "trash", role: .destructive) {
                                        Task { _ = await model.delete(meal) }
                                    }
                                }
                                .contextMenu {
                                    Button("Ajouter aux courses", systemImage: "cart.badge.plus") {
                                        Task { await model.sendToShopping(meal) }
                                    }
                                    Button("Supprimer", systemImage: "trash", role: .destructive) {
                                        Task { _ = await model.delete(meal) }
                                    }
                                }
                        }
                        Button("Ajouter un repas", systemImage: "plus") { newMealDay = NewMealDay(day: day) }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text(MealWeekDay.title(day))
                            .foregroundStyle(day == TodayBuckets.dayKey() ? Color.accentColor : .secondary)
                    }
                }
            }
        }
        .overlay { if model.week == nil && model.isLoading { ProgressView() } }
        .navigationTitle(weekTitle)
        .navigationDestination(for: Route.self) { route in
            if let meal = model.meal(route.id) { MealDetailView(model: model, mealID: meal.id) }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Semaine précédente", systemImage: "chevron.left") { Task { await model.shift(weeks: -1) } }
                if !model.isCurrentWeek {
                    Button("Cette semaine") { Task { await model.goToToday() } }
                }
                Button("Semaine suivante", systemImage: "chevron.right") { Task { await model.shift(weeks: 1) } }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Envoyer la semaine aux courses", systemImage: "cart.badge.plus") {
                    Task { await model.sendWeekToShopping() }
                }
                .disabled((model.week?.pendingIngredients ?? 0) == 0)
            }
        }
        .sheet(item: $newMealDay) { item in
            NavigationStack { MealEditorView(model: model, day: item.day) }
                #if os(macOS)
                .frame(minWidth: 420, minHeight: 380)
                #endif
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.load() } }
        }
        .alert("Erreur", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Courses", isPresented: noticeBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.notice ?? "")
        }
    }

    private var weekTitle: String {
        guard let week = model.week, let start = DayKey.date(week.start), let end = DayKey.date(week.end) else {
            return "Repas"
        }
        if model.isCurrentWeek { return "Repas de la semaine" }
        return "\(start.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated)))"
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    private var noticeBinding: Binding<Bool> {
        Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })
    }
}

private struct MealRow: View {
    let meal: Meal

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: meal.kind.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(meal.title)
                    if meal.isRecurring { Image(systemName: "repeat").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if meal.pendingIngredients == 0 && !meal.ingredients.isEmpty {
                Image(systemName: "cart.fill.badge.checkmark").foregroundStyle(.green)
                    .accessibilityLabel("Ingrédients sur la liste")
            }
        }
    }

    private var details: String {
        var parts = [meal.kind.label]
        if let cook = meal.cookName { parts.append(cook) }
        let count = meal.ingredients.isEmpty ? meal.recipeIngredientCount : meal.ingredients.count
        if count > 0 { parts.append("\(count) ingrédient\(count > 1 ? "s" : "")") }
        return parts.joined(separator: " · ")
    }
}

struct MealDetailView: View {
    let model: MealsModel
    let mealID: Int
    @State private var newIngredient = ""
    @State private var confirmDelete = false
    @State private var editing = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let meal = model.meal(mealID) {
            Form {
                Section {
                    Label(meal.kind.label, systemImage: meal.kind.symbol)
                    if let day = DayKey.date(meal.date) {
                        LabeledContent("Jour", value: day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    }
                    if let cook = meal.cookName { LabeledContent("Cuisine", value: cook) }
                    if let link = meal.recipeURL.flatMap(URL.init(string:)), link.scheme?.hasPrefix("http") == true {
                        Link(destination: link) { Label("Voir la recette", systemImage: "book") }
                    }
                }
                if let notes = meal.notes, !notes.isEmpty {
                    Section("Notes") { Text(notes) }
                }
                Section {
                    ForEach(meal.ingredients) { ingredient in
                        HStack {
                            Text([ingredient.quantity, ingredient.name].compactMap(\.self).joined(separator: " "))
                            Spacer()
                            if ingredient.onShoppingList {
                                Image(systemName: "cart.fill").foregroundStyle(.green).font(.caption)
                                    .accessibilityLabel("Sur la liste")
                            }
                        }
                        .swipeActions {
                            Button("Supprimer", systemImage: "trash", role: .destructive) {
                                Task { await model.deleteIngredient(ingredient, of: meal) }
                            }
                        }
                        .contextMenu {
                            Button("Supprimer", systemImage: "trash", role: .destructive) {
                                Task { await model.deleteIngredient(ingredient, of: meal) }
                            }
                        }
                    }
                    if meal.ingredients.isEmpty && meal.recipeIngredientCount > 0 {
                        Text("\(meal.recipeIngredientCount) ingrédients viennent de la recette liée.")
                            .foregroundStyle(.secondary)
                    }
                    TextField("Ajouter : 2 oignons, du riz…", text: $newIngredient)
                        .submitLabel(.done)
                        .onSubmit {
                            let text = newIngredient
                            newIngredient = ""
                            Task { await model.addIngredients(text, to: meal) }
                        }
                } header: {
                    Text("Ingrédients")
                }
                Section {
                    Button("Ajouter aux courses\(model.targetList.map { " (\($0.name))" } ?? "")",
                           systemImage: "cart.badge.plus") {
                        Task { await model.sendToShopping(meal) }
                    }
                    .disabled(meal.pendingIngredients == 0)
                    Button("Supprimer le repas", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } footer: {
                    if meal.isRecurring {
                        Text("Repas récurrent : supprimer ne retire que ce jour-là.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(meal.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) { Button("Modifier") { editing = true } }
            }
            .sheet(isPresented: $editing) {
                NavigationStack {
                    MealEditorView(model: model, day: meal.date, meal: meal) {
                        if model.meal(mealID) == nil { dismiss() } // moved to another week
                    }
                }
                #if os(macOS)
                .frame(minWidth: 420, minHeight: 380)
                #endif
            }
            .confirmationDialog("Supprimer « \(meal.title) » ?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) {
                    Task { if await model.delete(meal) { dismiss() } }
                }
            }
        } else {
            ContentUnavailableView("Repas introuvable", systemImage: "fork.knife")
        }
    }
}

/// Create a meal, or edit one (`meal` set): ingredients are then managed on the detail screen.
struct MealEditorView: View {
    let model: MealsModel
    var meal: Meal?
    var onSaved: () -> Void = {}
    @State private var day: Date
    @State private var kind: Meal.Kind
    @State private var title: String
    @State private var notes: String
    @State private var ingredients = ""
    @State private var saving = false
    @FocusState private var titleFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: MealsModel, day: String, meal: Meal? = nil, onSaved: @escaping () -> Void = {}) {
        self.model = model
        self.meal = meal
        self.onSaved = onSaved
        _day = State(initialValue: DayKey.date(day) ?? .now)
        // Evening by default; the morning before 10 suggests lunch.
        let hour = Calendar.current.component(.hour, from: .now)
        _kind = State(initialValue: meal?.kind ?? (hour < 10 ? .lunch : .dinner))
        _title = State(initialValue: meal?.title ?? "")
        _notes = State(initialValue: meal?.notes ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("Plat", text: $title).font(.headline).focused($titleFocused)
                Picker("Repas", selection: $kind) {
                    ForEach(Meal.Kind.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                DatePicker("Jour", selection: $day, displayedComponents: .date)
            }
            if meal == nil {
                Section {
                    TextField("2 oignons, du riz, de la crème…", text: $ingredients, axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    Text("Ingrédients")
                } footer: {
                    Text("Séparez par des virgules ou « et ». Vous pourrez ensuite les envoyer aux courses.")
                }
            } else {
                Section {
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...6)
                } footer: {
                    if meal?.isRecurring == true { Text("Repas récurrent : seul ce jour-là est modifié.") }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(meal == nil ? "Nouveau repas" : "Modifier le repas")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(meal == nil ? "Ajouter" : "Enregistrer") {
                    Task {
                        saving = true
                        let name = title.trimmingCharacters(in: .whitespaces)
                        let date = TodayBuckets.dayKey(day)
                        let ok = if let meal {
                            await model.update(meal, date: date, kind: kind, title: name, notes: notes)
                        } else {
                            await model.create(date: date, kind: kind, title: name, ingredients: ingredients)
                        }
                        saving = false
                        if ok { dismiss(); onSaved() }
                    }
                }
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .task { if meal == nil { titleFocused = true } }
    }
}
