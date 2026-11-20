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

    /// Applies the style to every window. More reliable than preferredColorScheme(nil),
    /// which often does not return to "system" until the app restarts.
    func apply() {
        let style: UIUserInterfaceStyle = self == .light ? .light : self == .dark ? .dark : .unspecified
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { window.overrideUserInterfaceStyle = style }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        ZStack {
            (scheme == .dark ? Color(red: 0.04, green: 0.05, blue: 0.08) : Color(red: 0.95, green: 0.96, blue: 0.98))
            if let img = carousel.displayBackdrop {
                // Small image + blur: same look as blurring the full photo, far cheaper.
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 24)
                    .opacity(scheme == .dark ? 0.6 : 0.5)
                    .id(carousel.displayIndex)
                    .transition(.opacity)
            } else {
                GeometryReader { geo in
                    let w = geo.size.width, h = geo.size.height
                    ZStack {
                        blob(Palette.mint, w * 0.9, x: w * (drift ? 0.15 : 0.35), y: h * (drift ? 0.25 : 0.15))
                        blob(Palette.violet, w * 1.0, x: w * (drift ? 0.9 : 0.7), y: h * (drift ? 0.4 : 0.55))
                        blob(Palette.rose, w * 0.8, x: w * (drift ? 0.4 : 0.2), y: h * (drift ? 0.9 : 0.8))
                    }
                }
                .blur(radius: 70)
                .opacity(scheme == .dark ? 0.45 : 0.35)
                // One long Core Animation transition instead of redrawing every frame.
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) { drift = true }
                }
            }
            LinearGradient(colors: [.clear, (scheme == .dark ? Color.black : Color.white).opacity(0.35)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
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
    var timeColor: Color = .white
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
                // Approximation: the real digits are drawn by the watch firmware
                // with the selected time style.
                TimelineView(.everyMinute) { context in
                    VStack(spacing: size * 0.01) {
                        Text(context.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                            .font(.system(size: size * 0.2, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text(context.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                            .font(.system(size: size * 0.065, weight: .medium, design: .rounded))
                            .opacity(0.85)
                    }
                    .foregroundStyle(timeColor)
                    .shadow(color: .black.opacity(0.35), radius: 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                    .padding(size * 0.13)
                }
            }
        }
        .frame(width: size, height: round ? size : size * 284 / 240)
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
