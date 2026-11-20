import SwiftUI

// MARK: - Appearance

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "Automático"
        case .light: return "Claro"
        case .dark: return "Oscuro"
        }
    }
    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum Palette {
    static let mint = Color(red: 0.37, green: 0.88, blue: 0.71)
    static let violet = Color(red: 0.55, green: 0.45, blue: 0.98)
    static let rose = Color(red: 0.98, green: 0.47, blue: 0.62)
    static let sky = Color(red: 0.35, green: 0.66, blue: 0.98)
}

// MARK: - Living background (photos from the carousel, or soft moving light)

struct AmbientBackground: View {
    @EnvironmentObject var carousel: PhotoCarousel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            (scheme == .dark ? Color(red: 0.04, green: 0.05, blue: 0.08) : Color(red: 0.95, green: 0.96, blue: 0.98))
            if let img = carousel.displayImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 50)
                    .opacity(scheme == .dark ? 0.55 : 0.45)
                    .id(carousel.displayIndex)
                    .transition(.opacity)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 20)) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    GeometryReader { geo in
                        let w = geo.size.width, h = geo.size.height
                        ZStack {
                            blob(Palette.mint, w * 0.9, x: w * (0.25 + 0.12 * sin(t / 7)), y: h * (0.2 + 0.08 * cos(t / 9)))
                            blob(Palette.violet, w * 1.0, x: w * (0.8 + 0.1 * cos(t / 8)), y: h * (0.45 + 0.1 * sin(t / 6)))
                            blob(Palette.rose, w * 0.8, x: w * (0.3 + 0.15 * cos(t / 10)), y: h * (0.85 + 0.06 * sin(t / 7)))
                        }
                    }
                }
                .blur(radius: 70)
                .opacity(scheme == .dark ? 0.45 : 0.35)
            }
            LinearGradient(colors: [.clear, (scheme == .dark ? Color.black : Color.white).opacity(0.35)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 1.2), value: carousel.displayIndex)
    }

    private func blob(_ c: Color, _ size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Circle().fill(c).frame(width: size, height: size).position(x: x, y: y)
    }
}

// MARK: - Glass surfaces

struct GlassCard: ViewModifier {
    var radius: CGFloat = 26
    var padding: CGFloat = 18
    @Environment(\.colorScheme) private var scheme

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: radius))
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.28 : 0.7),
                                                          .white.opacity(0.05)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing),
                                  lineWidth: 1)
            )
            .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.08), radius: 18, y: 8)
    }
}

extension View {
    func glassCard(radius: CGFloat = 26, padding: CGFloat = 18) -> some View {
        modifier(GlassCard(radius: radius, padding: padding))
    }
}

/// Pill-shaped glass button.
struct GlassButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : Color.primary)
            .background {
                if prominent {
                    Capsule().fill(Palette.mint.gradient)
                } else {
                    Capsule().fill(.thinMaterial)
                }
            }
            .overlay(Capsule().strokeBorder(.white.opacity(prominent ? 0 : 0.25), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(enabled ? 1 : 0.4)
            .animation(.spring(response: 0.25), value: configuration.isPressed)
    }
}

struct SectionTitle: View {
    let text: String
    var icon: String? = nil
    var body: some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon).foregroundStyle(Palette.mint) }
            Text(text).font(.headline)
        }
    }
}

struct Chip: View {
    let text: String
    var on = true
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(on ? Palette.mint.opacity(0.22) : Color.primary.opacity(0.07)))
            .overlay(Capsule().strokeBorder(on ? Palette.mint.opacity(0.6) : Color.primary.opacity(0.12), lineWidth: 1))
            .foregroundStyle(on ? Color.primary : Color.secondary)
    }
}

/// Watch-shaped preview (round or rounded-rect) with a sample time.
struct WatchPreview: View {
    let image: UIImage?
    var round = true
    var showTime = true
    var position: FaceStudio.Position = .top
    var amber = false
    var size: CGFloat = 200

    var body: some View {
        let shape: AnyShape = round ? AnyShape(Circle())
                                    : AnyShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
            if showTime {
                Text("10:42")
                    .font(.system(size: size * 0.2, weight: .thin, design: .rounded))
                    .foregroundStyle(amber ? Color(red: 1, green: 0.84, blue: 0.63) : .white)
                    .shadow(color: .black.opacity(0.4), radius: 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                    .padding(size * 0.16)
            }
        }
        .frame(width: size, height: round ? size : size * 1.22)
        .clipShape(shape)
        .overlay(shape.stroke(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.05)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 3))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
    }

    private var alignment: Alignment {
        switch position {
        case .top: return .top
        case .bottom: return .bottom
        case .left: return .leading
        case .right: return .trailing
        }
    }
}
