import SwiftUI
import FitCloudKit

// MARK: - Mood

enum PetMood: String {
    case radiant, happy, calm, hungry, sleepy, lonely, sad

    var label: String {
        switch self {
        case .radiant: return "Radiante"
        case .happy: return "Feliz"
        case .calm: return "Tranquila"
        case .hungry: return "Con hambre"
        case .sleepy: return "Durmiendo"
        case .lonely: return "Te extraña"
        case .sad: return "Un poco triste"
        }
    }

    var line: String {
        switch self {
        case .radiant: return "¡Cumpliste tu meta de pasos! Está llena de energía."
        case .happy: return "Vas por buen camino; le encanta moverse contigo."
        case .calm: return "Descansando a tu lado. Un paseo le vendría bien."
        case .hungry: return "Hace rato que no come. Dale algo rico."
        case .sleepy: return "Es de noche y está dormida. Shhh…"
        case .lonely: return "Hace tiempo que no ve tu reloj."
        case .sad: return "Necesita cariño: tócala para acariciarla."
        }
    }

    fileprivate enum Eyes { case open, happy, closed }
    fileprivate enum Mouth { case grin, smile, small, open, line, frown }

    fileprivate var eyes: Eyes {
        switch self {
        case .radiant, .happy: return .happy
        case .sleepy: return .closed
        default: return .open
        }
    }

    fileprivate var mouth: Mouth {
        switch self {
        case .radiant: return .grin
        case .happy: return .smile
        case .calm: return .small
        case .hungry: return .open
        case .sleepy: return .line
        case .lonely, .sad: return .frown
        }
    }
}

// MARK: - Engine

/// A small Tamagotchi-like companion fed by the watch: steps → energy,
/// sleep → rest, plus hunger and affection that change over time.
final class PetEngine: ObservableObject {
    static let shared = PetEngine()

    static let colors: [Color] = [
        Color(red: 0.42, green: 0.86, blue: 0.70),  // menta
        Color(red: 0.72, green: 0.62, blue: 1.00),  // lila
        Color(red: 1.00, green: 0.70, blue: 0.56),  // durazno
        Color(red: 0.50, green: 0.74, blue: 1.00),  // cielo
        Color(red: 1.00, green: 0.86, blue: 0.45),  // limón
    ]

    @Published var name: String { didSet { d.set(name, forKey: "k62.pet.name") } }
    @Published var colorIndex: Int { didSet { d.set(colorIndex, forKey: "k62.pet.color") } }
    @Published var stepGoal: Int { didSet { d.set(stepGoal, forKey: "k62.pet.goal") } }
    @Published var autoFace: Bool {
        didSet {
            d.set(autoFace, forKey: "k62.pet.autoFace")
            // Only one feature may own the watch face at a time.
            if autoFace && PhotoCarousel.shared.mode == .rotate { PhotoCarousel.shared.mode = .off }
            if autoFace { updateFaceIfDue() }
        }
    }
    @Published private(set) var steps = 0
    @Published private(set) var sleepMinutes = 0
    @Published private(set) var hunger: Double      // 0 = satisfied … 100 = starving
    @Published private(set) var affection: Double   // 0 … 100
    @Published private(set) var hasNativePetGame: Bool?
    @Published private(set) var lastSync: Date?

    let born: Date
    private let d = UserDefaults.standard
    private var lastTick: Date
    private var lastFaceUpdate: Date?
    private var lastFaceMood: String?
    private var installing = false
    private var timer: Timer?

    private init() {
        let d = UserDefaults.standard
        name = d.string(forKey: "k62.pet.name") ?? "Mochi"
        colorIndex = d.integer(forKey: "k62.pet.color")
        let goal = d.integer(forKey: "k62.pet.goal")
        stepGoal = goal == 0 ? 6000 : goal
        autoFace = d.bool(forKey: "k62.pet.autoFace")
        hunger = d.object(forKey: "k62.pet.hunger") as? Double ?? 20
        affection = d.object(forKey: "k62.pet.affection") as? Double ?? 70
        born = d.object(forKey: "k62.pet.born") as? Date ?? Date()
        lastTick = d.object(forKey: "k62.pet.tick") as? Date ?? Date()
        lastFaceUpdate = d.object(forKey: "k62.pet.faceDate") as? Date
        lastFaceMood = d.string(forKey: "k62.pet.faceMood")
        if d.object(forKey: "k62.pet.born") == nil { d.set(born, forKey: "k62.pet.born") }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
    }

    var color: Color { Self.colors[min(max(colorIndex, 0), Self.colors.count - 1)] }
    var energy: Double { stepGoal > 0 ? min(1, Double(steps) / Double(stepGoal)) : 0 }
    var ageDays: Int { max(1, (Calendar.current.dateComponents([.day], from: born, to: Date()).day ?? 0) + 1) }

    var mood: PetMood {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour >= 23 || hour < 7 { return .sleepy }
        if hunger > 70 { return .hungry }
        if !Watch.shared.ready, let last = lastSync, Date().timeIntervalSince(last) > 3 * 3600 { return .lonely }
        if affection < 25 { return .sad }
        if steps >= stepGoal { return .radiant }
        if steps >= stepGoal / 2 { return .happy }
        return .calm
    }

    // MARK: Time passes

    private func tick() {
        let hours = Date().timeIntervalSince(lastTick) / 3600
        guard hours > 0 else { return }
        hunger = min(100, hunger + hours * 5)
        affection = max(0, affection - hours * 3)
        lastTick = Date()
        save()
    }

    private func save() {
        d.set(hunger, forKey: "k62.pet.hunger")
        d.set(affection, forKey: "k62.pet.affection")
        d.set(lastTick, forKey: "k62.pet.tick")
    }

    // MARK: Interactions

    func feed() {
        tick()
        hunger = max(0, hunger - 40)
        affection = min(100, affection + 3)
        save()
    }

    func caress() {
        tick()
        affection = min(100, affection + 8)
        save()
    }

    func play() {
        tick()
        affection = min(100, affection + 5)
        hunger = min(100, hunger + 6)
        save()
    }

    // MARK: Watch data

    /// Reads today's steps/sleep from the K62 and checks the native pet game.
    func refresh() {
        tick()
        objectWillChange.send()  // mood also depends on the clock
        guard Watch.shared.ready else { return }
        FitCloudKit.requestHealthAndSportsDataToday { [weak self] ok, _, data, _ in
            DispatchQueue.main.async {
                guard let self, ok, let data else { return }
                self.steps = Int(data.steps)
                self.sleepMinutes = Int(data.deepSleepInMinutes + data.lightSleepInMinutes)
                self.lastSync = Date()
                self.updateFaceIfDue()
            }
        }
        if hasNativePetGame == nil {
            FitCloudKit.getSupportedGames { [weak self] ok, games, _ in
                DispatchQueue.main.async {
                    guard ok else { return }
                    // FITCLOUDGAME_PETDEV = 0 ("pet raising game") in FitCloudKitDefines.h
                    let list: [FitCloudGameObject] = games ?? []
                    self?.hasNativePetGame = list.contains { (game: FitCloudGameObject) -> Bool in
                        game.category.rawValue == 0
                    }
                }
            }
        }
    }

    // MARK: Pet on the watch face

    @MainActor
    func faceImage(for ui: FitCloudWatchfaceUIInfo?) -> UIImage? {
        let size = ui?.screenResolution() ?? CGSize(width: 466, height: 466)
        let side = min(size.width, size.height)
        let content = ZStack {
            Color.black
            PetView(mood: mood, color: color, size: side * 0.6, animated: false)
                .offset(y: size.height * 0.14)
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        return renderer.uiImage
    }

    @MainActor
    func installFace() {
        guard !installing, let img = faceImage(for: Watch.shared.faceUI) else { return }
        installing = true
        let current = mood.rawValue
        FaceStudio.shared.install(bk: img, ui: Watch.shared.faceUI, position: .top, color: .white) { [weak self] ok in
            guard let self else { return }
            self.installing = false
            guard ok else { return }
            self.lastFaceUpdate = Date()
            self.lastFaceMood = current
            self.d.set(self.lastFaceUpdate, forKey: "k62.pet.faceDate")
            self.d.set(current, forKey: "k62.pet.faceMood")
        }
    }

    /// Auto mode: refresh the face when the mood changed (at most every 3 h) or
    /// every 12 h. Each update is a full watch-face install, so it is rationed.
    func updateFaceIfDue() {
        guard autoFace, Watch.shared.ready, FaceStudio.shared.templateReady, !FaceStudio.shared.busy, !installing else { return }
        let age = lastFaceUpdate.map { Date().timeIntervalSince($0) } ?? .infinity
        let changed = mood.rawValue != lastFaceMood
        guard (changed && age > 3 * 3600) || age > 12 * 3600 else { return }
        Task { @MainActor in self.installFace() }
    }
}

// MARK: - Drawing

private struct SmileArc: Shape {
    var inverted = false
    func path(in r: CGRect) -> Path {
        var p = Path()
        if inverted {
            p.move(to: CGPoint(x: r.minX, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.midX, y: r.minY - r.height))
        } else {
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY + r.height))
        }
        return p
    }
}

struct PetView: View {
    let mood: PetMood
    let color: Color
    var size: CGFloat = 200
    var animated = true
    @State private var bob = false

    var body: some View {
        Group {
            if animated {
                TimelineView(.periodic(from: .now, by: 0.12)) { ctx in
                    figure(blink: Self.blinking(ctx.date))
                }
            } else {
                figure(blink: false)
            }
        }
        .frame(width: size, height: size)
        .offset(y: animated && bob ? -size * 0.03 : 0)
        .onAppear {
            guard animated else { return }
            withAnimation(.easeInOut(duration: mood == .sleepy ? 2.4 : 1.1).repeatForever(autoreverses: true)) { bob = true }
        }
    }

    private static func blinking(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4.2) < 0.14
    }

    private var ink: Color { Color(white: 0.12) }

    private func figure(blink: Bool) -> some View {
        let s = size
        return ZStack {
            Ellipse().fill(Color.black.opacity(0.22))
                .frame(width: s * 0.55, height: s * 0.07)
                .blur(radius: s * 0.02)
                .offset(y: s * 0.41)
            Circle().fill(color).frame(width: s * 0.22, height: s * 0.22).offset(x: -s * 0.25, y: -s * 0.27)
            Circle().fill(color).frame(width: s * 0.22, height: s * 0.22).offset(x: s * 0.25, y: -s * 0.27)
            Ellipse()
                .fill(color)
                .overlay(
                    Ellipse().fill(LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .top, endPoint: .center))
                )
                .overlay(
                    Ellipse().fill(Color.white.opacity(0.35))
                        .frame(width: s * 0.16, height: s * 0.08)
                        .rotationEffect(.degrees(-25))
                        .offset(x: -s * 0.2, y: -s * 0.17)
                )
                .frame(width: s * 0.82, height: s * 0.7)
                .offset(y: s * 0.04)
            Circle().fill(Color(red: 1, green: 0.45, blue: 0.55).opacity(0.35))
                .frame(width: s * 0.1, height: s * 0.1).offset(x: -s * 0.24, y: s * 0.09)
            Circle().fill(Color(red: 1, green: 0.45, blue: 0.55).opacity(0.35))
                .frame(width: s * 0.1, height: s * 0.1).offset(x: s * 0.24, y: s * 0.09)
            eye(blink).offset(x: -s * 0.14, y: -s * 0.03)
            eye(blink).offset(x: s * 0.14, y: -s * 0.03)
            mouth.offset(y: s * 0.13)
            if mood == .sleepy {
                Text("z Z")
                    .font(.system(size: s * 0.11, weight: .heavy, design: .rounded))
                    .foregroundStyle(color.opacity(0.9))
                    .offset(x: s * 0.33, y: -s * 0.38)
            }
        }
    }

    @ViewBuilder
    private func eye(_ blink: Bool) -> some View {
        let s = size
        switch blink ? .closed : mood.eyes {
        case .open:
            Capsule().fill(ink)
                .frame(width: s * 0.075, height: s * 0.11)
                .overlay(Circle().fill(.white).frame(width: s * 0.026, height: s * 0.026).offset(x: s * 0.012, y: -s * 0.025))
        case .happy:
            SmileArc(inverted: true)
                .stroke(ink, style: StrokeStyle(lineWidth: s * 0.026, lineCap: .round))
                .frame(width: s * 0.1, height: s * 0.04)
        case .closed:
            Capsule().fill(ink).frame(width: s * 0.09, height: s * 0.02)
        }
    }

    @ViewBuilder
    private var mouth: some View {
        let s = size
        let line = StrokeStyle(lineWidth: s * 0.024, lineCap: .round)
        switch mood.mouth {
        case .grin:
            SmileArc().fill(ink).frame(width: s * 0.18, height: s * 0.06)
                .overlay(SmileArc().stroke(ink, style: line).frame(width: s * 0.18, height: s * 0.06))
        case .smile:
            SmileArc().stroke(ink, style: line).frame(width: s * 0.14, height: s * 0.05)
        case .small:
            SmileArc().stroke(ink, style: line).frame(width: s * 0.08, height: s * 0.025)
        case .open:
            Ellipse().fill(ink).frame(width: s * 0.06, height: s * 0.075)
        case .line:
            Capsule().fill(ink).frame(width: s * 0.06, height: s * 0.016)
        case .frown:
            SmileArc(inverted: true).stroke(ink, style: line).frame(width: s * 0.1, height: s * 0.035)
        }
    }
}

// MARK: - Tab

struct StatBar: View {
    let label: String
    let value: Double
    let detail: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.subheadline.weight(.medium))
                Spacer()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                Capsule().fill(Color.primary.opacity(0.08))
                    .overlay(alignment: .leading) {
                        Capsule().fill(color.gradient)
                            .frame(width: max(6, g.size.width * CGFloat(min(max(value, 0), 1))))
                    }
            }
            .frame(height: 8)
        }
    }
}

struct PetTabView: View {
    private struct Heart: Identifiable {
        let id = UUID()
        let x = CGFloat.random(in: -70...70)
    }

    @EnvironmentObject var pet: PetEngine
    @EnvironmentObject var watch: Watch
    @EnvironmentObject var studio: FaceStudio
    @State private var hearts: [Heart] = []
    @State private var squish = false

    var body: some View {
        Page(title: pet.name) {
            VStack(spacing: 6) {
                ZStack {
                    PetView(mood: pet.mood, color: pet.color, size: 220)
                        .scaleEffect(x: squish ? 1.08 : 1, y: squish ? 0.92 : 1)
                        .id(pet.mood.rawValue + "\(pet.colorIndex)")
                        .onTapGesture { caress() }
                    ForEach(hearts) { heart in
                        Image(systemName: "heart.fill")
                            .font(.title2)
                            .foregroundStyle(Palette.rose)
                            .offset(x: heart.x, y: -90)
                            .transition(.asymmetric(insertion: .scale.combined(with: .opacity), removal: .move(edge: .top).combined(with: .opacity)))
                    }
                }
                .frame(height: 240)
                Text(pet.mood.label).font(.title3.weight(.semibold))
                Text(pet.mood.line).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .glassCard()

            VStack(spacing: 14) {
                StatBar(label: "Energía", value: pet.energy,
                        detail: "\(pet.steps) de \(pet.stepGoal) pasos", color: Palette.mint)
                StatBar(label: "Saciedad", value: (100 - pet.hunger) / 100,
                        detail: "\(Int(100 - pet.hunger))%", color: Color.orange)
                StatBar(label: "Cariño", value: pet.affection / 100,
                        detail: "\(Int(pet.affection))%", color: Palette.rose)
                if pet.sleepMinutes > 0 {
                    StatBar(label: "Descanso", value: Double(pet.sleepMinutes) / 480,
                            detail: String(format: "%.1f h", Double(pet.sleepMinutes) / 60), color: Palette.violet)
                }
                Text(pet.lastSync == nil ? "Conecta el reloj para que sienta tus pasos." :
                        "Edad: \(pet.ageDays) días · Datos del K62 actualizados")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .glassCard()

            HStack(spacing: 12) {
                Button { withAnimation(.spring()) { pet.feed() } } label: { Label("Alimentar", systemImage: "fork.knife") }
                    .buttonStyle(GlassButtonStyle(prominent: true))
                Button { play() } label: { Label("Jugar", systemImage: "sparkles") }
                    .buttonStyle(GlassButtonStyle())
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "Personalizar", icon: "paintpalette")
                TextField("Nombre", text: $pet.name)
                    .textInputAutocapitalization(.words)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
                HStack(spacing: 12) {
                    ForEach(PetEngine.colors.indices, id: \.self) { i in
                        Circle().fill(PetEngine.colors[i])
                            .frame(width: 34, height: 34)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(pet.colorIndex == i ? 0.8 : 0), lineWidth: 2))
                            .onTapGesture { withAnimation { pet.colorIndex = i } }
                    }
                }
                Stepper("Meta diaria: \(pet.stepGoal) pasos", value: $pet.stepGoal, in: 2000...20000, step: 500)
                    .font(.subheadline)
            }
            .glassCard()

            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "En el reloj", icon: "applewatch")
                if let native = pet.hasNativePetGame {
                    Text(native ? "Tu K62 trae un juego de mascota propio: búscalo en Juegos del reloj."
                                : "El firmware del K62 no trae juego de mascota; puedes llevar a \(pet.name) en la esfera.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Poner a \(pet.name) en la esfera") { pet.installFace() }
                    .buttonStyle(GlassButtonStyle(prominent: true))
                    .disabled(!watch.ready || !studio.templateReady || studio.busy)
                Toggle("Cambiar la esfera según su ánimo", isOn: $pet.autoFace)
                    .tint(Palette.mint)
                if !studio.templateReady {
                    Text("Necesita la plantilla de esfera (pestaña Esfera).").font(.caption).foregroundStyle(.orange)
                }
                Text("Cada cambio instala la esfera (menos de un minuto). En automático se actualiza como mucho cada 3 horas, solo cuando cambia su ánimo. Desactiva la esfera rotativa de fotos.")
                    .font(.caption2).foregroundStyle(.secondary)
                StudioProgress()
            }
            .glassCard()
        }
        .onAppear { pet.refresh() }
    }

    private func caress() {
        pet.caress()
        let heart = Heart()
        withAnimation(.spring(response: 0.35)) {
            hearts.append(heart)
            squish = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { withAnimation(.spring()) { squish = false } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            withAnimation(.easeOut(duration: 0.6)) { hearts.removeAll { $0.id == heart.id } }
        }
    }

    private func play() {
        pet.play()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.4)) { squish = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { withAnimation(.spring()) { squish = false } }
    }
}
