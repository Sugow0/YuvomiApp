import SwiftUI
import YuvomiKit

struct MealsView: View {
    @State private var model: MealsModel
    @State private var newMealDay: NewMealDay?
    @State private var selectedDay: String?
    @State private var showingAutoPlan = false
    @State private var confirmingUndo = false
    @Namespace private var daySpace
    @Environment(\.scenePhase) private var scenePhase

    init(client: YuvomiClient) {
        _model = State(initialValue: MealsModel(client: client))
    }

    private struct Route: Hashable { let id: Int }
    struct NewMealDay: Identifiable { let day: String; var id: String { day } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ScreenHeader("Repas", eyebrow: weekLine) { headerActions }
                if let week = model.week, let day = shownDay(in: week) {
                    dayStrip(week, selected: day).riseIn()
                    dayContent(week, day: day)
                    laterTray(week, after: day)
                } else if model.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .animation(.ySnappy, value: model.week)
            .animation(.ySmooth, value: selectedDay)
        }
        .screenChrome(title: "Repas")
        .navigationDestination(for: Route.self) { route in
            if let meal = model.meal(route.id) { MealDetailView(model: model, mealID: meal.id) }
        }
        .sheet(item: $newMealDay) { item in
            NavigationStack { MealEditorView(model: model, day: item.day) }
                #if os(macOS)
                .frame(minWidth: 420, minHeight: 380)
                #endif
        }
        .sheet(isPresented: $showingAutoPlan) {
            NavigationStack { AutoPlanRecipesView(model: model) }
                #if os(macOS)
                .frame(minWidth: 420, minHeight: 480)
                #endif
        }
        .confirmationDialog("Annuler le planning auto ?", isPresented: $confirmingUndo, titleVisibility: .visible) {
            Button("Retirer les repas et leurs ingrédients", role: .destructive) {
                Task { await model.undoAutoPlan(emptyingList: false) }
            }
            Button("Retirer les repas et vider la liste", role: .destructive) {
                Task { await model.undoAutoPlan(emptyingList: true) }
            }
            Button("Garder", role: .cancel) {}
        } message: {
            Text("Les \(model.undoableMeals) repas créés par le dernier « Planifier les repas » seront supprimés. Les repas ajoutés à la main restent.")
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

    // MARK: - En-tête

    @ViewBuilder private var headerActions: some View {
        RoundIconButton(title: "Semaine précédente", systemImage: "chevron.left") {
            Task { await model.shift(weeks: -1) }
        }
        RoundIconButton(title: "Semaine suivante", systemImage: "chevron.right") {
            Task { await model.shift(weeks: 1) }
        }
        Menu {
            if !model.isCurrentWeek {
                Button("Cette semaine", systemImage: "arrow.uturn.backward") {
                    Task { await model.goToToday() }
                }
            }
            Button("Envoyer la semaine aux courses", systemImage: "cart.badge.plus") {
                Task { await model.sendWeekToShopping() }
            }
            .disabled((model.week?.pendingIngredients ?? 0) == 0)
            Button("Recettes du planning auto", systemImage: "wand.and.stars") {
                showingAutoPlan = true
            }
            if model.undoableMeals > 0 {
                Button("Annuler le planning auto", systemImage: "arrow.uturn.backward.circle", role: .destructive) {
                    confirmingUndo = true
                }
            }
        } label: {
            RoundIcon(systemImage: "ellipsis")
        }
        .headerMenuStyle()
        .accessibilityLabel("Plus d'options")
    }

    private var weekLine: String {
        guard let week = model.week, let start = DayKey.date(week.start), let end = DayKey.date(week.end) else {
            return "Semaine"
        }
        if model.isCurrentWeek { return "Semaine du \(start.formatted(.dateTime.day().month(.wide)))" }
        return "\(start.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated)))"
    }

    /// Le jour choisi s'il est dans la semaine affichée, sinon aujourd'hui, sinon le premier jour.
    private func shownDay(in week: MealWeek) -> String? {
        if let selectedDay, week.days.contains(selectedDay) { return selectedDay }
        let today = TodayBuckets.dayKey()
        return week.days.contains(today) ? today : week.days.first
    }

    // MARK: - Bande des jours

    private func dayStrip(_ week: MealWeek, selected: String) -> some View {
        let today = TodayBuckets.dayKey()
        return HStack(spacing: 2) {
            ForEach(week.days, id: \.self) { day in
                let isSelected = day == selected
                let planned = !week.meals(on: day).isEmpty
                Button {
                    withAnimation(.ySnappy) { selectedDay = day }
                } label: {
                    VStack(spacing: 3) {
                        Text(Self.letter(day))
                            .font(Typo.eyebrow)
                            .foregroundStyle(isSelected ? Palette.onActiveSecondary : Palette.inkSecondary)
                        Text(Self.number(day))
                            .font(Typo.body.weight(.heavy))
                            .foregroundStyle(isSelected ? Palette.onActive : (day < today ? Palette.inkSecondary : Palette.ink))
                        Circle()
                            .fill(planned ? (isSelected ? Palette.onActive : Palette.accent) : Color.clear)
                            .frame(width: 5, height: 5)
                    }
                    .frame(maxWidth: .infinity, minHeight: 68)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: Radius.row + 2, style: .continuous)
                                .fill(Palette.activeTray)
                                .elevation(.high)
                                .matchedGeometryEffect(id: "day", in: daySpace)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(MealWeekDay.title(day))
                .accessibilityValue(planned ? "Repas prévu" : "Rien de prévu")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(8)
        .background(Palette.tray, in: .rect(cornerRadius: Radius.tray, style: .continuous))
        .elevation(.low)
        .sensoryFeedback(.selection, trigger: selectedDay)
    }

    private static func letter(_ day: String) -> String {
        guard let date = DayKey.date(day) else { return "" }
        return date.formatted(.dateTime.weekday(.narrow)).uppercased()
    }

    private static func number(_ day: String) -> String {
        guard let date = DayKey.date(day) else { return day }
        return date.formatted(.dateTime.day())
    }

    private static func shortDay(_ day: String) -> String {
        guard let date = DayKey.date(day) else { return day }
        let text = date.formatted(.dateTime.weekday(.abbreviated).day())
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    // MARK: - Le jour choisi

    @ViewBuilder private func dayContent(_ week: MealWeek, day: String) -> some View {
        let meals = week.meals(on: day)
        let main = Self.featured(meals, day: day)
        if let main {
            featuredTray(main, day: day)
                .id(main.id)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
        let others = meals.filter { $0.id != main?.id }
        Tray {
            TrayHeader(MealWeekDay.title(day)) {
                Text(meals.isEmpty ? "Rien de prévu" : (meals.count == 1 ? "1 repas" : "\(meals.count) repas"))
            }
            ForEach(others) { meal in
                NavigationLink(value: Route(id: meal.id)) { MealTrayRow(meal: meal) }
                    .buttonStyle(.pressable)
                    .contextMenu { mealMenu(meal) }
                    .accessibilityAction(named: "Supprimer") { Task { _ = await model.delete(meal) } }
            }
            Button { newMealDay = NewMealDay(day: day) } label: {
                HStack(spacing: 14) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Palette.accent)
                        .frame(width: 28, height: 28)
                    Text("Ajouter un repas")
                        .font(Typo.body)
                        .foregroundStyle(Palette.ink)
                }
                .trayRow()
                .contentShape(.rect(cornerRadius: Radius.row))
            }
            .buttonStyle(.pressable)
        }
        .riseIn(delay: 0.08)
    }

    /// Le repas mis en avant : celui de midi le matin pour aujourd'hui, sinon celui du soir.
    private static func featured(_ meals: [Meal], day: String) -> Meal? {
        let hour = Calendar.current.component(.hour, from: .now)
        if day == TodayBuckets.dayKey(), hour < 14, let lunch = meals.first(where: { $0.kind == .lunch }) {
            return lunch
        }
        return meals.first { $0.kind == .dinner } ?? meals.first { $0.kind == .lunch } ?? meals.first
    }

    private func featuredTray(_ meal: Meal, day: String) -> some View {
        Tray(style: .active) {
            HStack {
                Text(Self.eyebrow(meal, day: day))
                    .font(Typo.eyebrow)
                    .tracking(0.8)
                    .foregroundStyle(Palette.onActiveSecondary)
                Spacer()
                NavigationLink(value: Route(id: meal.id)) {
                    Text("Détails")
                        .font(Typo.caption)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 32)
                        .background(Palette.activeTrayInset, in: .capsule)
                }
                .buttonStyle(.pressable)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(meal.title)
                    .font(Typo.hero)
                    .lineLimit(2)
                if meal.isRecurring {
                    Image(systemName: "repeat")
                        .font(.caption)
                        .foregroundStyle(Palette.onActiveSecondary)
                        .accessibilityLabel("Récurrent")
                }
            }
            if let details = Self.details(meal, includeKind: false) {
                Text(details)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.onActiveSecondary)
            }
            if !meal.ingredients.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(meal.ingredients) { ingredient in
                        IngredientChip(ingredient: ingredient)
                    }
                }
                .padding(.top, 4)
            } else if meal.recipeIngredientCount > 0 {
                Text("\(meal.recipeIngredientCount) ingrédients viennent de la recette liée.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.onActiveSecondary)
            }
            if meal.pendingIngredients > 0 {
                Button {
                    Task { await model.sendToShopping(meal) }
                } label: {
                    Text(meal.pendingIngredients == 1
                         ? "Ajouter l'ingrédient manquant aux courses"
                         : "Ajouter les \(meal.pendingIngredients) manquants aux courses")
                        .font(Typo.body)
                        .foregroundStyle(Palette.activeTray)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Palette.onActive, in: .capsule)
                }
                .buttonStyle(.pressable)
                .padding(.top, 6)
            }
        }
        .contextMenu { mealMenu(meal) }
    }

    private static func eyebrow(_ meal: Meal, day: String) -> String {
        guard day == TodayBuckets.dayKey() else { return meal.kind.label.uppercased() }
        switch meal.kind {
        case .lunch: return "CE MIDI"
        case .dinner: return "CE SOIR"
        default: return meal.kind.label.uppercased()
        }
    }

    static func details(_ meal: Meal, includeKind: Bool) -> String? {
        var parts: [String] = []
        if includeKind { parts.append(meal.kind.label) }
        if let cook = meal.cookName { parts.append("\(cook) cuisine") }
        let count = meal.ingredients.isEmpty ? meal.recipeIngredientCount : meal.ingredients.count
        if count > 0 { parts.append("\(count) ingrédient\(count > 1 ? "s" : "")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private func mealMenu(_ meal: Meal) -> some View {
        Button("Ajouter aux courses", systemImage: "cart.badge.plus") {
            Task { await model.sendToShopping(meal) }
        }
        if meal.ingredients.isEmpty {
            Button("Remplacer", systemImage: "arrow.triangle.2.circlepath") {
                Task { await model.replace(meal) }
            }
        }
        if let recipeID = meal.recipeID {
            let excluded = model.excludedRecipes.contains(recipeID)
            Button(excluded ? "Reproposer en automatique" : "Ne plus proposer en automatique",
                   systemImage: excluded ? "wand.and.stars" : "wand.and.stars.inverse") {
                model.setAutoPlan(excluded, recipeID: recipeID)
            }
        }
        Button("Supprimer", systemImage: "trash", role: .destructive) {
            Task { _ = await model.delete(meal) }
        }
    }

    // MARK: - Plus tard

    @ViewBuilder private func laterTray(_ week: MealWeek, after day: String) -> some View {
        let later = week.days.filter { $0 > day }
        if !later.isEmpty {
            Tray {
                TrayHeader("Plus tard cette semaine")
                ForEach(later, id: \.self) { next in
                    let meals = week.meals(on: next)
                    Button {
                        withAnimation(.ySnappy) { selectedDay = next }
                    } label: {
                        HStack(spacing: 14) {
                            Text(Self.shortDay(next))
                                .font(Typo.caption.weight(.heavy))
                                .padding(.horizontal, 12)
                                .frame(minWidth: 64, minHeight: 36)
                                .background(Palette.tray, in: .capsule)
                            Text(Self.featured(meals, day: next)?.title ?? "Rien de prévu")
                                .font(Typo.body)
                                .foregroundStyle(meals.isEmpty ? Palette.inkSecondary : Palette.ink)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if meals.count > 1 {
                                Text("+\(meals.count - 1)")
                                    .font(Typo.caption)
                                    .foregroundStyle(Palette.inkSecondary)
                            }
                        }
                        .trayRow(minHeight: 56, leading: 10)
                        .contentShape(.rect(cornerRadius: Radius.row))
                    }
                    .buttonStyle(.pressable)
                }
            }
            .riseIn(delay: 0.12)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    private var noticeBinding: Binding<Bool> {
        Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })
    }
}

/// Un repas secondaire du jour, posé dans un plateau blanc.
private struct MealTrayRow: View {
    let meal: Meal

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: meal.kind.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 36, height: 36)
                .background(Palette.tray, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(meal.title)
                    .font(Typo.body)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                if let details = MealsView.details(meal, includeKind: true) {
                    Text(details)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.inkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if meal.pendingIngredients == 0 && !meal.ingredients.isEmpty {
                Image(systemName: "cart.fill.badge.checkmark")
                    .foregroundStyle(Palette.accent)
                    .accessibilityLabel("Ingrédients sur la liste")
            }
        }
        .trayRow(minHeight: 60, leading: 12)
        .contentShape(.rect(cornerRadius: Radius.row))
    }
}

/// Un ingrédient dans le plateau noir : coché s'il est déjà sur la liste, en contour sinon.
private struct IngredientChip: View {
    let ingredient: Meal.Ingredient

    var body: some View {
        let label = [ingredient.quantity, ingredient.name].compactMap(\.self).joined(separator: " ")
        HStack(spacing: 6) {
            if ingredient.onShoppingList {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Palette.onAccent)
                    .frame(width: 18, height: 18)
                    .background(Palette.accent, in: .circle)
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .heavy))
            }
            Text(label)
                .font(Typo.caption)
                .lineLimit(1)
        }
        .padding(.leading, ingredient.onShoppingList ? 7 : 11)
        .padding(.trailing, 12)
        .frame(minHeight: 32)
        .foregroundStyle(ingredient.onShoppingList ? Palette.onActive : Palette.onActiveSecondary)
        .background {
            if ingredient.onShoppingList {
                Capsule().fill(Palette.activeTrayInset)
            } else {
                Capsule().strokeBorder(Palette.onActiveSecondary.opacity(0.6), lineWidth: 1.5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label + (ingredient.onShoppingList ? ", sur la liste" : ", manquant"))
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
                    if meal.ingredients.isEmpty {
                        Button("Remplacer par une autre recette", systemImage: "arrow.triangle.2.circlepath") {
                            Task { await model.replace(meal) }
                        }
                    }
                    Button("Supprimer le repas", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } footer: {
                    if meal.isRecurring {
                        Text("Repas récurrent : supprimer ne retire que ce jour-là.")
                    }
                }
            }
            .clearsTabBar()
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
