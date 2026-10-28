import AppKit
import SwiftUI

/// CTW Design System 2027 (Liquid Glass Edition) – Tokens und Bausteine.
///
/// Grundsätze: Glas nur für Navigation und kurze Werkzeuge, Inhalte auf deckenden Flächen.
/// Die wichtigste Aktion ist deckend (Red 600). Status wird nie nur über Farbe vermittelt.
enum CTW {
    // MARK: Markenfarben (unverändert aus v4.1)

    static let teal900 = Color(hex: 0x17383E)
    static let teal700 = Color(hex: 0x3A666D)
    static let teal500 = Color(hex: 0x8AC2CD)
    static let teal200 = Color(hex: 0xD9ECEF)
    static let sand50 = Color(hex: 0xF5F1EA)
    static let stone50 = Color(hex: 0xF2F6F8)
    static let red600 = Color(hex: 0xC53637)
    static let red100 = Color(hex: 0xFFE2DE)
    static let grey500 = Color(hex: 0x6E7D83)

    // MARK: Rollen (hell / dunkel)

    static let bg = Color(light: 0xF5F1EA, dark: 0x0B1317)
    static let surface = Color(light: 0xFFFFFF, dark: 0x131F24)
    static let surfaceSoft = Color(light: 0xF2F6F8, dark: 0x192930)
    static let ink = Color(light: 0x17383E, dark: 0xF2F6F8)
    static let muted = Color(light: 0x3E5156, dark: 0xAEBABF)
    static let line = Color(light: 0xB1C1C4, dark: 0x4F5D63)
    static let lineSoft = Color(light: 0xCDDADD, dark: 0x324045)
    static let accent = Color(light: 0x3A666D, dark: 0x81C4D0)
    static let action = red600
    static let focus = Color(light: 0x0049AE, dark: 0x63C5FF)
    static let glassFill = Color(light: 0xF8FDFE, dark: 0x101D22)
    /// Getönte Fläche für Hinweise in Akzentfarbe (Teal 200 hell, Teal 900 dunkel).
    static let accentSoft = Color(light: 0xD9ECEF, dark: 0x17383E)
    static let actionSoft = Color(light: 0xFFE2DE, dark: 0x3A1A1B)

    // MARK: Form & Bewegung

    static let radius: CGFloat = 8
    static let fast = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.14)
    static let base = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.22)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    /// Farbe, die automatisch zwischen hellem und dunklem Erscheinungsbild wechselt.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

// MARK: - Flächen

/// Deckende Lesefläche (SOLID): für Text, Listen und Formulare.
struct CTWCard: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CTW.surface, in: RoundedRectangle(cornerRadius: CTW.radius))
            .overlay(RoundedRectangle(cornerRadius: CTW.radius).strokeBorder(CTW.lineSoft))
            .shadow(color: CTW.teal900.opacity(0.06), radius: 3, y: 1)
    }
}

/// Glasfläche (GLASS REGULAR/THICK): nur für Navigation und kurze Werkzeuge.
/// Bei „Transparenz reduzieren“ wird sie automatisch deckend.
struct CTWGlass: ViewModifier {
    var strong = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: CTW.radius)
        content
            .background {
                if reduceTransparency {
                    shape.fill(CTW.surface)
                } else {
                    shape.fill(.ultraThinMaterial)
                        .overlay(shape.fill(CTW.glassFill.opacity(strong ? 0.95 : 0.86)))
                }
            }
            .overlay {
                // Eine Lichtkante oben, ruhige Kante unten.
                shape.strokeBorder(
                    // Hell: Lichtkante 85 % Weiß. Dunkel: gedämpfte Kante (oklch 95 % / .25).
                    LinearGradient(colors: scheme == .dark
                                       ? [Color(hex: 0xE9EEF1, opacity: 0.25), Color(hex: 0xE9EEF1, opacity: 0.1)]
                                       : [.white.opacity(0.85), CTW.lineSoft.opacity(0.6)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
            }
            .shadow(color: CTW.teal900.opacity(reduceTransparency ? 0 : 0.13), radius: 4, y: 2)
    }
}

extension View {
    func ctwCard(padding: CGFloat = 16) -> some View { modifier(CTWCard(padding: padding)) }
    func ctwGlass(strong: Bool = false) -> some View { modifier(CTWGlass(strong: strong)) }
}

// MARK: - Typografie

/// Kleine Überschrift im Stil „01 / HANDLUNGEN“.
struct Eyebrow: View {
    let text: String
    var number: String?

    var body: some View {
        HStack(spacing: 6) {
            if let number {
                Text(number).monospacedDigit()
                Text("/")
            }
            Text(text.uppercased())
        }
        .font(.system(size: 11, weight: .semibold))
        .tracking(0.8)
        .foregroundStyle(CTW.muted)
    }
}

// MARK: - Schaltflächen

/// Primäre Aktion: deckend in Red 600.
struct CTWPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(CTW.action.opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.4),
                        in: RoundedRectangle(cornerRadius: CTW.radius))
            .contentShape(RoundedRectangle(cornerRadius: CTW.radius))
            .animation(CTW.fast, value: configuration.isPressed)
    }
}

/// Sekundäre Aktion: ruhig, deckend mit Kontur.
struct CTWSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(CTW.ink.opacity(isEnabled ? 1 : 0.45))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(configuration.isPressed ? CTW.surfaceSoft : CTW.surface,
                        in: RoundedRectangle(cornerRadius: CTW.radius))
            .overlay(RoundedRectangle(cornerRadius: CTW.radius).strokeBorder(CTW.line))
            .contentShape(RoundedRectangle(cornerRadius: CTW.radius))
            .animation(CTW.fast, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == CTWPrimaryButtonStyle {
    static var ctwPrimary: CTWPrimaryButtonStyle { .init() }
}

extension ButtonStyle where Self == CTWSecondaryButtonStyle {
    static var ctwSecondary: CTWSecondaryButtonStyle { .init() }
}

// MARK: - Kennzeichnungen

/// Kennzeichnung mit Text, optionalem Symbol und Kontur – Bedeutung nie nur über Farbe.
struct Badge: View {
    let text: String
    let color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.35)))
    }
}

/// Symbol in einer getönten, abgerundeten Fläche.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: CTW.radius * size / 36))
    }
}

/// CTW-Logo; im Dunkelmodus auf heller Fläche, da die Wortmarke Teal 900 ist.
/// Die Logodatei liegt nicht im Repository (Resources/ctw-logo.png, lokal) – ohne sie erscheint ein Schriftzug.
struct CTWLogo: View {
    var height: CGFloat = 22
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let image = Bundle.main.image(forResource: "ctw-logo") {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(height: height)
                .padding(scheme == .dark ? 4 : 0)
                .background(scheme == .dark ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 4))
                .accessibilityLabel("CTW Computer-Irrel")
        } else {
            HStack(spacing: height * 0.12) {
                Text("CTW")
                    .font(.system(size: height * 0.8, weight: .heavy))
                    .foregroundStyle(CTW.ink)
                VStack(spacing: height * 0.08) {
                    Rectangle().fill(CTW.action).frame(width: height * 0.28, height: height * 0.28)
                    Rectangle().fill(CTW.teal500).frame(width: height * 0.2, height: height * 0.2)
                }
            }
            .frame(height: height)
            .accessibilityLabel("CTW")
        }
    }
}

// MARK: - Bedeutungen

extension ThreadStatus {
    var color: Color {
        switch self {
        case .needsReply: CTW.action
        case .waiting: CTW.accent
        case .info: CTW.grey500
        case .done: CTW.teal700
        }
    }
}

extension Priority {
    var symbol: String {
        switch self {
        case .high: "exclamationmark.2"
        case .normal: "minus"
        case .low: "arrow.down"
        }
    }
}

extension CategoryRule {
    /// SF Symbol der Kategorie – frei wählbar oder aus dem Namen abgeleitet.
    var symbolName: String {
        if let icon, !icon.isEmpty { return icon }
        return CategoryRule.guessSymbol(for: name)
    }

    static func guessSymbol(for name: String) -> String {
        let n = name.lowercased()
        let map: [(String, String)] = [
            ("handlung", "hand.point.up.left.fill"), ("termin", "calendar"), ("persönlich", "person.fill"),
            ("rechnung", "doc.text.fill"), ("bestell", "shippingbox.fill"), ("benachrichtig", "bell.fill"),
            ("newsletter", "newspaper.fill"), ("werbung", "megaphone.fill"), ("info", "info.circle.fill"),
            ("archiv", "archivebox.fill"), ("kunde", "person.2.fill"), ("projekt", "folder.fill"),
        ]
        return map.first { n.contains($0.0) }?.1 ?? "tag.fill"
    }

    static let symbolChoices = [
        "tag.fill", "hand.point.up.left.fill", "calendar", "person.fill", "person.2.fill", "doc.text.fill",
        "eurosign.circle.fill", "shippingbox.fill", "bell.fill", "newspaper.fill", "megaphone.fill",
        "info.circle.fill", "archivebox.fill", "folder.fill", "briefcase.fill", "cart.fill", "airplane",
        "building.2.fill", "wrench.and.screwdriver.fill", "heart.fill", "star.fill", "lock.fill",
    ]
}

extension MailAccountInfo {
    var symbol: String {
        let n = (name + " " + emails.joined(separator: " ")).lowercased()
        if n.contains("icloud") || n.contains("me.com") || n.contains("mac.com") { return "icloud.fill" }
        if n.contains("google") || n.contains("gmail") { return "g.circle.fill" }
        if n.contains("exchange") { return "building.2.fill" }
        // Übrige Konten mit eigener Domain gelten als geschäftlich.
        return "building.2.fill"
    }
}

/// Menüleisten-Symbol: Briefumschlag mit CTW-Pixelquadraten, als Vorlagenbild (passt sich der Leiste an).
enum MenuBarIcon {
    static func image(busy: Bool) -> NSImage {
        let size = NSSize(width: 22, height: 16)
        let img = NSImage(size: size, flipped: false) { rect in
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            if let env = NSImage(systemSymbolName: busy ? "envelope.arrow.triangle.branch" : "envelope",
                                 accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let s = env.size
                env.draw(in: NSRect(x: 0, y: (rect.height - s.height) / 2, width: s.width, height: s.height))
            }
            // Pixelmotiv aus dem CTW-Logo.
            NSColor.black.setFill()
            NSBezierPath(rect: NSRect(x: 18, y: 11, width: 3.5, height: 3.5)).fill()
            NSBezierPath(rect: NSRect(x: 18, y: 6.5, width: 2.5, height: 2.5)).fill()
            NSBezierPath(rect: NSRect(x: 14.5, y: 13, width: 2.5, height: 2.5)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}
