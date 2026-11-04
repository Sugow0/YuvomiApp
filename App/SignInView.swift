import SwiftUI
import YuvomiKit

struct SignInView: View {
    @Environment(AppModel.self) private var model

    enum Method: String, CaseIterable, Identifiable {
        case password = "Mot de passe"
        case pairing = "Code de couplage"
        var id: Self { self }
    }

    @State private var method: Method = .password
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var pairingCode = ""
    @State private var pendingTwoFactor: AuthService.PendingTwoFactor?
    @State private var twoFactorCode = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Adresse du serveur", text: $server, prompt: Text("yuvomi.local:3000"))
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                } header: {
                    Text("Serveur")
                } footer: {
                    Text("L'adresse de votre instance Yuvomi. https est utilisé si vous n'indiquez rien.")
                }

                Picker("Méthode", selection: $method) {
                    ForEach(Method.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch method {
                case .password: passwordSection
                case .pairing: pairingSection
                }

                if let errorMessage {
                    Section { Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .navigationTitle("Connexion à Yuvomi")
            .disabled(isWorking)
            .overlay { if isWorking { ProgressView() } }
            .sheet(item: twoFactorBinding) { _ in twoFactorSheet }
            .task(id: model.pendingPairing) { await redeemPendingPairing() }
        }
    }

    // MARK: - Sections

    private var passwordSection: some View {
        Section {
            TextField("Nom d'utilisateur", text: $username)
                .textContentType(.username)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            SecureField("Mot de passe", text: $password)
                .textContentType(.password)
                .onSubmit { Task { await signInWithPassword() } }
            Button("Se connecter") { Task { await signInWithPassword() } }
                .disabled(server.isEmpty || username.isEmpty || password.isEmpty)
        }
    }

    private var pairingSection: some View {
        Section {
            TextField("Code", text: $pairingCode)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                #endif
            Button("Coupler cet appareil") { Task { await signInWithCode() } }
                .disabled(server.isEmpty || pairingCode.isEmpty)
        } footer: {
            Text("Dans l'app web : Réglages → Appareils → Ajouter. Scannez le QR code avec l'appareil photo, ou saisissez le code ici.")
        }
    }

    private var twoFactorSheet: some View {
        NavigationStack {
            Form {
                TextField("Code de vérification", text: $twoFactorCode)
                    .textContentType(.oneTimeCode)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                if pendingTwoFactor?.recoveryAvailable == true {
                    Text("Vous pouvez aussi saisir un code de récupération.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Double authentification")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { pendingTwoFactor = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Valider") { Task { await verifyTwoFactor() } }.disabled(twoFactorCode.isEmpty)
                }
            }
        }
        .frame(minWidth: 320, minHeight: 200)
    }

    private var twoFactorBinding: Binding<PendingTwoFactorBox?> {
        Binding(
            get: { pendingTwoFactor.map(PendingTwoFactorBox.init) },
            set: { pendingTwoFactor = $0?.value }
        )
    }

    // MARK: - Actions

    private func signInWithPassword() async {
        guard let serverURL = parsedServer() else { return }
        await run {
            switch try await model.makeAuthService().signIn(server: serverURL, username: username, password: password) {
            case .signedIn(let credential): await model.didSignIn(credential)
            case .twoFactorRequired(let pending): pendingTwoFactor = pending
            }
        }
    }

    private func verifyTwoFactor() async {
        guard let pending = pendingTwoFactor else { return }
        await run {
            let credential = try await model.makeAuthService().verifySecondFactor(pending, code: twoFactorCode)
            pendingTwoFactor = nil
            await model.didSignIn(credential)
        }
    }

    private func signInWithCode() async {
        guard let serverURL = parsedServer() else { return }
        var parts = URLComponents()
        parts.scheme = "yuvomi"
        parts.host = "pair"
        parts.queryItems = [
            URLQueryItem(name: "server", value: serverURL.origin.absoluteString),
            URLQueryItem(name: "code", value: pairingCode.trimmingCharacters(in: .whitespaces)),
        ]
        guard let url = parts.url, let link = PairingLink(url) else { return }
        await run { await model.didSignIn(try await model.makeAuthService().redeemPairing(link)) }
    }

    private func redeemPendingPairing() async {
        guard let link = model.pendingPairing else { return }
        model.pendingPairing = nil
        server = link.server.origin.absoluteString
        method = .pairing
        pairingCode = link.code
        await run { await model.didSignIn(try await model.makeAuthService().redeemPairing(link)) }
    }

    private func parsedServer() -> ServerURL? {
        guard let url = ServerURL(server) else {
            errorMessage = "Adresse de serveur invalide."
            return nil
        }
        return url
    }

    private func run(_ work: () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do { try await work() } catch { errorMessage = error.localizedDescription }
    }
}

/// `sheet(item:)` needs Identifiable; the pending state is used once.
private struct PendingTwoFactorBox: Identifiable {
    let id = UUID()
    let value: AuthService.PendingTwoFactor
}
