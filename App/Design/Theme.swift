import SwiftUI

// Piste C « Plateaux » : porcelaine et encre, un seul accent (Ube = AccentColor),
// des plateaux arrondis concentriques, des ombres en deux couches, des ressorts partout.

/// Couleurs du thème. Chacune a sa variante sombre dans Assets.xcassets.
/// En sombre, le plateau actif s'inverse : il devient clair sur fond nuit.
enum Palette {
    /// Fond des écrans.
    static var porcelain: Color { Color("Porcelain") }
    /// Plateau standard.
    static var tray: Color { Color("Tray") }
    /// Ligne posée dans un plateau.
    static var trayInset: Color { Color("TrayInset") }
    /// Texte principal.
    static var ink: Color { Color("Ink") }
    static var inkSecondary: Color { Color("InkSecondary") }
    /// Plateau actif : ce qui compte maintenant, l'îlot d'ajout.
    static var activeTray: Color { Color("ActiveTray") }
    static var activeTrayInset: Color { Color("ActiveTrayInset") }
    static var onActive: Color { Color("OnActive") }
    static var onActiveSecondary: Color { Color("OnActiveSecondary") }
    /// Le seul accent : cases, sélection, heure courante.
    static var accent: Color { .accentColor }
    static var accentSoft: Color { Color("AccentSoft") }
    static var accentSoftText: Color { Color("AccentSoftText") }
    /// Glyphe posé sur l'accent (la coche).
    static var onAccent: Color { Color("OnAccent") }
}

/// Arrondis concentriques : rayon intérieur = rayon extérieur − marge.
enum Radius {
    static let tray: CGFloat = 40
    static let trayPadding: CGFloat = 10
    /// 40 − 10.
    static let row: CGFloat = 30
    static let tile: CGFloat = 24
}

/// Une seule famille, SF Pro Rounded, en suivant Dynamic Type.
enum Typo {
    static let screenTitle = Font.system(.largeTitle, design: .rounded, weight: .heavy)
    static let hero = Font.system(.title, design: .rounded, weight: .heavy)
    static let trayTitle = Font.system(.title3, design: .rounded, weight: .heavy)
    static let body = Font.system(.body, design: .rounded, weight: .semibold)
    static let caption = Font.system(.footnote, design: .rounded, weight: .semibold)
    static let eyebrow = Font.system(.caption, design: .rounded, weight: .bold)
}

extension Animation {
    /// Taps, cases, interrupteurs.
    static let ySnappy = Animation.spring(duration: 0.3, bounce: 0.15)
    /// Un plateau qui grandit, l'îlot qui s'ouvre.
    static let yTray = Animation.spring(duration: 0.42, bounce: 0.22)
    /// Navigation, fondus de contenu.
    static let ySmooth = Animation.spring(duration: 0.5, bounce: 0)
}
