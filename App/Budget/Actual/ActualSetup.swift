import SwiftUI
import YuvomiKit

/// Budget section: Actual Budget once connected, Yuvomi's own budget otherwise.
struct BudgetRootView: View {
    @Environment(AppModel.self) private var app
    let client: YuvomiClient
    @State private var connecting = false

    var body: some View {
        Group {
            if let config = app.actualConfig {
                ActualBudgetView(config: config).id(config.budgetID)
            } else {
                BudgetView(client: client) { connecting = true }
            }
        }
        .sheet(isPresented: $connecting) {
            NavigationStack { ActualSetupView() }
                #if os(macOS)
                .frame(minWidth: 460, minHeight: 420)
                #endif
        }
    }
}

struct ActualSettingsSection: View {
    @Environment(AppModel.self) private var app
    @State private var connecting = false

    var body: some View {
        Section {
            if let config = app.actualConfig {
                LabeledContent("Budget", value: config.budgetName)
                LabeledContent("Serveur", value: config.server.origin.host() ?? config.server.origin.absoluteString)
                Button("Changer de budget ou de serveur") { connecting = true }
                Button("Déconnecter Actual Budget", role: .destructive) { app.actualConfig = nil }
            } else {
                Button("Connecter Actual Budget", systemImage: "link") { connecting = true }
            }
        } header: {
            Text("Actual Budget")
        } footer: {
            Text("Avec Actual connecté, la section Budget affiche vos comptes bancaires synchronisés par Actual, via actual-http-api.")
        }
        .sheet(isPresented: $connecting) {
            NavigationStack { ActualSetupView() }
                #if os(macOS)
                .frame(minWidth: 460, minHeight: 420)
                #endif
        }
    }
}

/// Address + API key of actual-http-api, then which budget file.
struct ActualSetupView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var apiKey = ""
    @State private var encryptionPassword = ""
    @State private var budgets: [ActualBudgetFile] = []
    @State private var selectedID: String?
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("actual-api.exemple.fr", text: $address)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                SecureField("Clé API (API_KEY)", text: $apiKey)
            } header: {
                Text("actual-http-api")
            } footer: {
                Text("L'adresse du conteneur actual-http-api (port 5007 par défaut), pas celle d'Actual lui-même.")
            }

            if budgets.isEmpty {
                Section {
                    Button {
                        Task { await check() }
                    } label: {
                        if checking { ProgressView() } else { Text("Vérifier la connexion") }
                    }
                    .disabled(address.isEmpty || apiKey.isEmpty || checking)
                }
            } else {
                Section("Budget") {
                    Picker("Fichier", selection: $selectedID) {
                        ForEach(budgets) { Text($0.name).tag(Optional($0.id)) }
                    }
                    SecureField("Mot de passe de chiffrement (facultatif)", text: $encryptionPassword)
                }
            }

            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Actual Budget")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Connecter", action: save).disabled(selectedID == nil)
            }
        }
        .onAppear {
            guard let config = app.actualConfig else { return }
            address = config.server.origin.absoluteString
            apiKey = config.apiKey
            encryptionPassword = config.encryptionPassword ?? ""
        }
    }

    private func check() async {
        guard let server = ServerURL(address) else { error = "Adresse invalide."; return }
        checking = true
        defer { checking = false }
        do {
            budgets = try await ActualClient.budgets(server: server, apiKey: apiKey.trimmingCharacters(in: .whitespaces))
                .filter { $0.groupId != nil }
            selectedID = budgets.first { $0.groupId == app.actualConfig?.budgetID }?.id ?? budgets.first?.id
            error = budgets.isEmpty ? "Aucun budget synchronisé sur ce serveur Actual." : nil
        } catch {
            self.error = error.userMessage
        }
    }

    private func save() {
        guard let server = ServerURL(address),
              let budget = budgets.first(where: { $0.id == selectedID }),
              let groupID = budget.groupId else { return }
        let password = encryptionPassword.trimmingCharacters(in: .whitespaces)
        app.actualConfig = ActualConfig(server: server, apiKey: apiKey.trimmingCharacters(in: .whitespaces),
                                        budgetID: groupID, budgetName: budget.name,
                                        encryptionPassword: password.isEmpty ? nil : password)
        dismiss()
    }
}
