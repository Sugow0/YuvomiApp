import SwiftUI
import YuvomiKit

/// What the "Planifier les repas" shortcut does with each recipe. Recipes from Mealie follow
/// their Mealie category (Plat, Dessert, anything else stays out), read through Mealie's API since
/// Yuvomi's sync does not carry categories; the device can still leave any recipe out.
struct AutoPlanRecipesView: View {
    let model: MealsModel
    @State private var recipes: [Recipe]?
    @State private var categories: [String: [String]]?
    @State private var mealie = MealieStore.load()
    @State private var mealieURL = MealieStore.load()?.server.origin.absoluteString ?? ""
    @State private var mealieToken = ""
    @State private var connecting = false
    @State private var search = ""
    @State private var failure: String?
    @State private var people = AutoPlanSettings().people
    @Environment(\.dismiss) private var dismiss

    private var shown: [Recipe] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let all = recipes ?? []
        return query.isEmpty ? all : all.filter { $0.title.localizedStandardContains(query) }
    }

    var body: some View {
        List {
            if search.isEmpty {
                Section {
                    Stepper("\(people) personne\(people > 1 ? "s" : "") à chaque repas", value: $people, in: 1...12)
                        .onChange(of: people) { _, value in AutoPlanSettings().people = value }
                } footer: {
                    Text("Le raccourci a aussi ce réglage ; la dernière valeur utilisée sert à « Remplacer ».")
                }
                mealieSection
            }
            if recipes != nil {
                Section {
                    ForEach(shown) { recipe in row(recipe) }
                } footer: {
                    Text(summary)
                }
            }
        }
        .overlay {
            if let failure, recipes == nil {
                ContentUnavailableView("Recettes indisponibles", systemImage: "wifi.exclamationmark", description: Text(failure))
            } else if recipes == nil {
                ProgressView()
            } else if shown.isEmpty, !search.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .searchable(text: $search, prompt: "Rechercher une recette")
        .navigationTitle("Planning auto")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
        }
        .task { await load() }
    }

    // MARK: - Mealie

    @ViewBuilder private var mealieSection: some View {
        Section {
            if let mealie {
                LabeledContent("Mealie", value: mealie.server.origin.host() ?? mealie.server.origin.absoluteString)
                Button("Déconnecter Mealie", role: .destructive) {
                    MealieStore.clear()
                    self.mealie = nil
                    categories = nil
                }
            } else {
                TextField("https://mealie.exemple.fr", text: $mealieURL)
                    .textContentType(.URL)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                SecureField("Jeton d'API", text: $mealieToken)
                Button(connecting ? "Connexion…" : "Connecter") { Task { await connect() } }
                    .disabled(connecting || ServerURL(mealieURL) == nil || mealieToken.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Catégories Mealie")
        } footer: {
            Text(mealie == nil
                 ? "Jeton : Mealie → Profil → Jetons d'API. Les recettes classées « Plat » vont midi et soir, « Dessert » en dessert ; les autres ne sont jamais planifiées."
                 : "Classez vos recettes dans Mealie : « Plat » midi et soir, « Dessert » en dessert. Les autres ne sont jamais planifiées.")
        }
    }

    private func connect() async {
        guard let server = ServerURL(mealieURL) else { return }
        connecting = true
        defer { connecting = false }
        let config = MealieConfig(server: server, token: mealieToken.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            categories = try await MealieClient(config: config).categoriesBySlug()
            try MealieStore.save(config)
            mealie = config
            mealieToken = ""
            failure = nil
        } catch {
            failure = error.localizedDescription
            model.errorMessage = error.localizedDescription
        }
    }

    private func load() async {
        do {
            recipes = try await model.client.recipes()
            if let mealie { categories = try await MealieClient(config: mealie).categoriesBySlug() }
        } catch {
            failure = error.localizedDescription
        }
    }

    // MARK: - Rows

    private enum Source { case mealie([String]), device }

    private func source(of recipe: Recipe) -> Source {
        if let categories, let slug = recipe.providerSlug { return .mealie(categories[slug] ?? []) }
        return .device
    }

    private var roles: RecipeRoles {
        let settings = AutoPlanSettings()
        return RecipeRoles(recipes: recipes ?? [], mealieCategories: categories,
                           excluded: model.excludedRecipes, localDesserts: settings.dessertRecipeIDs)
    }

    @ViewBuilder private func row(_ recipe: Recipe) -> some View {
        switch source(of: recipe) {
        case .mealie(let names):
            let planned = names.contains { [RecipeRoles.dishCategory, RecipeRoles.dessertCategory].contains($0.lowercased()) }
            if planned {
                Toggle(isOn: Binding(
                    get: { !model.excludedRecipes.contains(recipe.id) },
                    set: { model.setAutoPlan($0, recipeID: recipe.id) }
                )) { label(recipe, detail: names.joined(separator: ", ")) }
            } else {
                label(recipe, detail: names.isEmpty ? "Sans catégorie dans Mealie · non planifiée" : "\(names.joined(separator: ", ")) · non planifiée")
                    .foregroundStyle(.secondary)
            }
        case .device:
            Picker(selection: Binding(
                get: { model.role(of: recipe.id) },
                set: { model.setRole($0, recipeID: recipe.id) }
            )) {
                ForEach(MealsModel.RecipeRole.allCases) { Text($0.rawValue).tag($0) }
            } label: { label(recipe, detail: nil) }
        }
    }

    private func label(_ recipe: Recipe, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(recipe.title)
            Text([detail, portions(recipe)].compactMap(\.self).joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// "8 portions · 4 repas" for a dish, "8 portions · 3 jours" for a dessert.
    private func portions(_ recipe: Recipe) -> String {
        let size = recipe.servings.map { "\($0) portions" } ?? "portions non renseignées (compté 4)"
        let isDessert = roles.desserts.contains { $0.id == recipe.id }
        guard isDessert || roles.dishes.contains(where: { $0.id == recipe.id }) else { return size }
        let kind: Meal.Kind = isDessert ? .snack : .dinner
        let cover = BatchPlanner.coverage(servings: recipe.servings, people: people, meals: isDessert ? 1...3 : 2...4)
        let lasts = isDessert ? "\(cover.meals) jour\(cover.meals > 1 ? "s" : "")" : "\(cover.meals) repas"
        let factor = recipe.cookingFactor(people: people, for: kind)
        return "\(size) · \(lasts)\(factor > 1 ? " · quantités ×\(factor)" : "")"
    }

    private var summary: String {
        let roles = roles
        return "\(roles.dishes.count) plats et \(roles.desserts.count) desserts proposés. "
            + "Une recette se cuisine une fois et dure selon ses portions."
    }
}
