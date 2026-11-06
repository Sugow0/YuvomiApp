import SwiftUI

/// En-tête d'écran de la piste C : une petite ligne, un grand titre arrondi, des actions rondes.
struct ScreenHeader<Actions: View>: View {
    let title: String
    let eyebrow: String?
    let actions: Actions

    init(_ title: String, eyebrow: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.eyebrow = eyebrow
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let eyebrow {
                    Text(eyebrow)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.inkSecondary)
                        .lineLimit(1)
                }
                Text(title)
                    .font(Typo.screenTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) { actions }
                .padding(.bottom, 4)
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
    }
}

extension ScreenHeader where Actions == EmptyView {
    init(_ title: String, eyebrow: String? = nil) {
        self.init(title, eyebrow: eyebrow) { EmptyView() }
    }
}

/// Le rond des en-têtes, à utiliser comme étiquette d'un `Button` ou d'un `Menu`.
struct RoundIcon: View {
    let systemImage: String
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(prominent ? Palette.onActive : Palette.ink)
            .frame(width: 44, height: 44)
            .background(prominent ? Palette.activeTray : Palette.tray, in: .circle)
            .elevation(prominent ? .high : .low)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(.circle)
    }
}

/// Bouton rond d'en-tête.
struct RoundIconButton: View {
    let title: String
    let systemImage: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundIcon(systemImage: systemImage, prominent: prominent)
        }
        .buttonStyle(PressableStyle(scale: 0.92))
        .accessibilityLabel(title)
    }
}

/// Plateau d'état vide ou de chargement.
struct EmptyTray: View {
    let title: String
    let systemImage: String
    var message: String?

    var body: some View {
        Tray {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                Text(title).font(Typo.trayTitle)
                if let message {
                    Text(message)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.inkSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .padding(.horizontal, 16)
        }
    }
}

/// Champ de saisie posé dans un plateau (ajout rapide, recherche).
struct TrayField: View {
    let placeholder: String
    @Binding var text: String
    var systemImage = "plus"
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Palette.accent)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .submitLabel(.done)
                .onSubmit(onSubmit)
        }
        .trayRow()
    }
}

/// Pastilles de choix : la sélection est une pilule noire qui glisse de l'une à l'autre.
struct PillPicker<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    @Namespace private var pill

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(options, id: \.value) { option in
                    let selected = option.value == selection
                    Button {
                        withAnimation(.ySnappy) { selection = option.value }
                    } label: {
                        Text(option.label)
                            .font(Typo.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 40)
                            .foregroundStyle(selected ? Palette.onActive : Palette.ink)
                            .background {
                                if selected {
                                    Capsule()
                                        .fill(Palette.activeTray)
                                        .matchedGeometryEffect(id: "pill", in: pill)
                                }
                            }
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(5)
        }
        .background(Palette.tray, in: .rect(cornerRadius: 25, style: .continuous))
        .elevation(.low)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

extension View {
    /// Fond porcelaine et texte encre. À la racine d'un onglet iPhone, l'en-tête maison remplace
    /// la barre de navigation ; ailleurs (iPad, Mac, écran poussé) la barre reste, en petit.
    func screenChrome(title: String) -> some View {
        modifier(ScreenChrome(title: title))
    }
}

private struct ScreenChrome: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        content
            .foregroundStyle(Palette.ink)
            .background(Palette.porcelain)
            .navigationTitle(title)
            #if os(iOS)
            .modifier(PhoneNavigationBar())
            #endif
    }
}

extension EnvironmentValues {
    /// Vrai dans les onglets de l'iPhone (`CompactHome`) : la racine de chaque onglet a son
    /// en-tête maison et se passe de la barre de navigation.
    @Entry var usesScreenHeaders = false
}

#if os(iOS)
private struct PhoneNavigationBar: ViewModifier {
    @Environment(\.usesScreenHeaders) private var usesScreenHeaders
    /// Vrai pour un écran poussé dans une pile : il garde sa barre pour le bouton retour.
    @Environment(\.isPresented) private var isPushed

    func body(content: Content) -> some View {
        if usesScreenHeaders && !isPushed {
            content.toolbarVisibility(.hidden, for: .navigationBar)
        } else {
            content.navigationBarTitleDisplayMode(.inline)
        }
    }
}
#endif

extension View {
    /// Un `Menu` d'en-tête qui garde l'aspect du rond (sans bordure ni chevron sur Mac).
    func headerMenuStyle() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}
