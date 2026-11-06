import SwiftUI

enum TrayStyle {
    /// Plateau blanc (gris nuit en sombre) qui range le contenu.
    case plain
    /// Plateau noir (clair en sombre) pour ce qui compte maintenant.
    case active
}

/// Le conteneur de base de la piste C : un plateau arrondi, posé avec une ombre en deux couches.
struct Tray<Content: View>: View {
    let style: TrayStyle
    /// Marge intérieure. Par défaut 22 pour un plateau actif (contenu « héros »), 10 sinon
    /// (des lignes de rayon 30 dans un plateau de rayon 40).
    let padding: CGFloat?
    let content: Content

    init(style: TrayStyle = .plain, padding: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.style = style
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
        }
        .padding(padding ?? (style == .active ? 22 : Radius.trayPadding))
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(style == .active ? Palette.onActive : Palette.ink)
        .background(style == .active ? Palette.activeTray : Palette.tray,
                    in: .rect(cornerRadius: Radius.tray, style: .continuous))
        .elevation(style == .active ? .high : .low)
    }
}

/// Titre d'un plateau, aligné sur le rayon de ses lignes.
struct TrayHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(Typo.trayTitle)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
                .font(Typo.caption)
                // Relatif à la couleur du plateau : marche sur un plateau blanc comme noir.
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 44)
    }
}

extension TrayHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

extension View {
    /// Une ligne posée dans un plateau : rayon 30 dans un plateau de rayon 40 et de marge 10.
    func trayRow(minHeight: CGFloat = 60, leading: CGFloat = 16, fill: Color = Palette.trayInset) -> some View {
        padding(.leading, leading)
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .background(fill, in: .rect(cornerRadius: Radius.row, style: .continuous))
    }

    func elevation(_ level: Elevation.Level) -> some View {
        modifier(Elevation(level: level))
    }

    /// Le plateau monte à son apparition, avec un léger décalage pour faire une cascade.
    func riseIn(delay: Double = 0) -> some View {
        modifier(RiseIn(delay: delay))
    }
}

/// Toujours deux ombres : une nette, une diffuse. Plus marquées en sombre.
struct Elevation: ViewModifier {
    enum Level { case low, high }

    let level: Level
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let boost = colorScheme == .dark ? 3.0 : 1.0
        let high = level == .high
        content
            .shadow(color: .black.opacity((high ? 0.12 : 0.05) * boost), radius: high ? 2 : 1, y: 1)
            .shadow(color: .black.opacity((high ? 0.18 : 0.06) * boost), radius: high ? 20 : 15, y: high ? 18 : 12)
    }
}

struct RiseIn: ViewModifier {
    let delay: Double
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 28)
            .onAppear {
                guard !shown else { return }
                let animation = reduceMotion ? Animation.easeOut(duration: 0.2) : Animation.yTray.delay(delay)
                withAnimation(animation) { shown = true }
            }
    }
}

/// Tout ce qui se touche s'enfonce un peu puis revient sur un ressort.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.ySnappy, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}
