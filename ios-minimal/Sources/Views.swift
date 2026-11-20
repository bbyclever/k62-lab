import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import FitCloudKit
import FitCloudWhatsApp

struct RootView: View {
    @EnvironmentObject var watch: Watch

    var body: some View {
        TabView {
            HomeView().tabItem { Label("Reloj", systemImage: "applewatch") }
            FaceView().tabItem { Label("Esfera", systemImage: "circle.hexagongrid") }
            PhotosView().tabItem { Label("Fotos", systemImage: "photo.stack") }
            AlertsView().tabItem { Label("Avisos", systemImage: "bell.badge") }
            PetTabView().tabItem { Label("Mascota", systemImage: "pawprint") }
            // Minimal: the WhatsApp tab only exists when the firmware can use it
            // (keeps 5 tabs on the K62, so iOS never folds them into "More").
            if watch.supportsWhatsApp {
                WhatsAppView().tabItem { Label("WhatsApp", systemImage: "bubble.left.and.text.bubble.right") }
            }
        }
    }
}

/// Shared page scaffold: living background + glass cards + appearance menu.
struct Page<Content: View>: View {
    let title: String
    let content: Content
    @AppStorage("k62.theme") private var theme = AppTheme.system.rawValue

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) { content }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
            }
            .background { AmbientBackground() }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Picker("Apariencia", selection: $theme) {
                            ForEach(AppTheme.allCases) { t in
                                Label(t.label, systemImage: t.icon).tag(t.rawValue)
                            }
                        }
                    } label: {
                        Image(systemName: (AppTheme(rawValue: theme) ?? .system).icon)
                    }
                }
            }
        }
    }
}

// MARK: - Reloj

struct HomeView: View {
    @EnvironmentObject var watch: Watch
    @EnvironmentObject var carousel: PhotoCarousel
    @AppStorage("k62.face.design") private var design = "2-orbita"

    var body: some View {
        Page(title: "K62") {
            hero
            if !watch.connected { pairing }
            if !watch.capabilities.isEmpty { capabilities }
            log
            if watch.connected {
                Button("Desconectar", role: .destructive) { watch.disconnect() }
                    .buttonStyle(GlassButtonStyle())
            }
        }
    }

    private var hero: some View {
        HStack(spacing: 18) {
            WatchPreview(image: (carousel.displayImage ?? FaceStudio.background(design, for: watch.faceUI))
                            .map { FaceStudio.compose($0, ui: watch.faceUI, style: .saved) },
                         round: watch.faceUI?.isRound() ?? false,
                         position: FaceStyle.saved.position,
                         timeColor: Color(uiColor: FaceStyle.saved.color), size: 118)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(watch.ready ? Palette.mint : watch.connected ? Color.orange : Color.gray)
                        .frame(width: 9, height: 9)
                    Text(watch.ready ? "Conectado" : watch.status).font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                }
                if let b = watch.battery {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Batería \(b)%").font(.caption).foregroundStyle(.secondary)
                        GeometryReader { g in
                            Capsule().fill(Color.primary.opacity(0.1))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(Palette.mint.gradient).frame(width: g.size.width * CGFloat(b) / 100)
                                }
                        }
                        .frame(height: 6)
                    }
                }
                Text("Firmware \(watch.firmware)").font(.caption).foregroundStyle(.secondary)
                Text("Bluetooth: \(watch.bluetooth)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .glassCard()
    }

    private var pairing: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Vincular", icon: "link")
            Button(watch.scanning ? "Buscando…" : "Buscar K62") { watch.scan() }
                .buttonStyle(GlassButtonStyle(prominent: true))
                .disabled(watch.scanning)
            ForEach(watch.devices) { d in
                Button { watch.bind(d) } label: {
                    HStack {
                        Image(systemName: "applewatch.radiowaves.left.and.right")
                        Text(d.name).fontWeight(.medium)
                        Spacer()
                        Text(d.rssi.map { "\($0) dBm" } ?? "conectado a iOS")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
            }
            Text("Confirma en el reloj. Se empareja también el Bluetooth de llamadas y música.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .glassCard()
    }

    private var capabilities: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Este firmware permite", icon: "cpu")
            ForEach(watch.capabilities) { c in
                HStack {
                    Text(c.name).font(.subheadline)
                    Spacer()
                    Chip(text: c.value, on: c.good && c.value != "No")
                }
            }
        }
        .glassCard()
    }

    private var log: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(watch.log.prefix(30).enumerated()), id: \.offset) { item in
                    Text(item.element).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 8)
        } label: {
            SectionTitle(text: "Registro", icon: "list.bullet.rectangle")
        }
        .glassCard()
    }
}

// MARK: - Esfera

struct FaceView: View {
    @EnvironmentObject var watch: Watch
    @EnvironmentObject var studio: FaceStudio
    @AppStorage("k62.face.design") private var design = "2-orbita"
    @AppStorage("k62.face.position") private var positionRaw = FaceStudio.Position.bottom.rawValue
    @AppStorage("k62.face.timeStyle") private var timeStyle = -1
    @AppStorage("k62.face.colorHex") private var colorHex = "FFFFFF"
    @AppStorage("k62.face.glass") private var glass = true
    @State private var custom: UIImage?
    @State private var pick: PhotosPickerItem?
    @State private var importing = false
    @State private var confirm = false

    private static let swatches = ["FFFFFF", "FFD6A0", "5EE0B5", "FF7A9C", "7CC4FF", "1C1C1E"]

    private var position: FaceStudio.Position { FaceStudio.Position(rawValue: positionRaw) ?? .bottom }
    private var style: FaceStyle { FaceStyle(position: position, timeStyle: timeStyle, colorHex: colorHex, glass: glass) }
    private var background: UIImage? { custom ?? FaceStudio.background(design, for: watch.faceUI) }
    /// Exactly the background that will be written to the watch.
    private var composed: UIImage? { background.map { FaceStudio.compose($0, ui: watch.faceUI, style: style) } }
    private var round: Bool { watch.faceUI?.isRound() ?? false }
    private var colorBinding: Binding<Color> {
        Binding(get: { Color(uiColor: UIColor(hex: colorHex)) },
                set: { colorHex = UIColor($0).hexString })
    }

    var body: some View {
        Page(title: "Esfera") {
            WatchPreview(image: composed, round: round, position: position,
                         timeColor: Color(uiColor: UIColor(hex: colorHex)), size: 230)
                .padding(.vertical, 12)

            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "Fondo", icon: "photo")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(FaceStudio.designs, id: \.self) { d in
                            if let img = FaceStudio.background(d, for: watch.faceUI) {
                                let selected = design == d && custom == nil
                                let shape = RoundedRectangle(cornerRadius: round ? 32 : 12, style: .continuous)
                                Image(uiImage: img).resizable().scaledToFill()
                                    .frame(width: 54, height: round ? 54 : 64)
                                    .clipShape(shape)
                                    .overlay(shape.strokeBorder(selected ? Palette.mint : Color.white.opacity(0.25),
                                                                lineWidth: selected ? 3 : 1))
                                    .onTapGesture { withAnimation(.spring()) { design = d; custom = nil } }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                PhotosPicker(selection: $pick, matching: .images) {
                    Label(custom == nil ? "Usar una foto propia" : "Cambiar foto", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(GlassButtonStyle())
                Toggle(isOn: $glass) {
                    Label("Panel de cristal detrás de la hora", systemImage: "rectangle.on.rectangle")
                }
                .tint(Palette.mint)
            }
            .glassCard()

            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "Hora en el reloj", icon: "textformat.size")
                Picker("Posición", selection: $positionRaw) {
                    ForEach(FaceStudio.Position.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tipografía del reloj").font(.subheadline.weight(.medium))
                    Picker("Tipografía", selection: $timeStyle) {
                        Text("Auto").tag(-1)
                        ForEach(0..<6, id: \.self) { Text("\($0 + 1)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("Son los estilos de hora y fecha que trae el firmware del K62 (más gruesos o más finos). La vista previa es aproximada: prueba cada número en el reloj.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    ForEach(Self.swatches, id: \.self) { hex in
                        Circle().fill(Color(uiColor: UIColor(hex: hex)))
                            .frame(width: 30, height: 30)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(colorHex == hex ? 0.85 : 0.2),
                                                           lineWidth: colorHex == hex ? 2.5 : 1))
                            .onTapGesture { colorHex = hex }
                    }
                    Spacer(minLength: 0)
                    ColorPicker("Color de la hora", selection: colorBinding, supportsOpacity: false)
                        .labelsHidden()
                }
            }
            .glassCard()

            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "Instalar", icon: "square.and.arrow.down.on.square")
                if studio.templateReady {
                    HStack {
                        Label("Plantilla del reloj lista", systemImage: "checkmark.seal.fill").foregroundStyle(Palette.mint)
                        Spacer()
                        Button("Cambiar") { studio.removeTemplate() }
                            .font(.caption.weight(.semibold))
                            .disabled(studio.busy)
                    }
                } else {
                    HStack(spacing: 10) {
                        Button("Obtener plantilla") { if let ui = watch.faceUI { studio.fetchTemplate(ui: ui) } }
                            .buttonStyle(GlassButtonStyle())
                            .disabled(watch.faceUI == nil)
                        Button("Importar .bin") { importing = true }
                            .buttonStyle(GlassButtonStyle())
                    }
                }
                Button(studio.busy ? "Instalando…" : "Instalar en el reloj") { confirm = true }
                    .buttonStyle(GlassButtonStyle(prominent: true))
                    .disabled(!watch.ready || !studio.templateReady || studio.busy || background == nil)
                StudioProgress()
            }
            .glassCard()

            if let slots = watch.faceUI?.slots, !slots.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(text: "Esferas en el reloj", icon: "square.stack")
                    ForEach(slots, id: \.slotIndex) { s in
                        HStack {
                            Text("Ranura \(s.slotIndex)").font(.subheadline)
                            Text("nº \(s.watchfaceNo)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Mostrar") { watch.showFace(slot: Int(s.slotIndex)) }
                                .font(.caption.weight(.semibold))
                            if s.slotType.rawValue != 0 {
                                Button(role: .destructive) { watch.deleteFace(slot: Int(s.slotIndex)) } label: {
                                    Image(systemName: "trash")
                                }
                                .padding(.leading, 8)
                            }
                        }
                    }
                }
                .glassCard()
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "bin") ?? .data, .data]) { result in
            if case .success(let url) = result { studio.importTemplate(from: url) }
        }
        .onChange(of: pick) { item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    await MainActor.run { custom = img }
                }
            }
        }
        .confirmationDialog("¿Instalar esta esfera en el K62?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Instalar") {
                if let bk = background { studio.install(bk: bk, ui: watch.faceUI, style: style) }
            }
        } message: {
            Text("El reloj entrará en modo de actualización durante la transferencia. Mantenlo cerca del iPhone.")
        }
    }
}

struct StudioProgress: View {
    @EnvironmentObject var studio: FaceStudio
    var body: some View {
        if studio.busy || studio.progress > 0 {
            ProgressView(value: min(max(studio.progress, 0), 1)).tint(Palette.mint)
        }
        if !studio.message.isEmpty {
            Text(studio.message).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Fotos (carrusel)

struct PhotosView: View {
    @EnvironmentObject var watch: Watch
    @EnvironmentObject var studio: FaceStudio
    @EnvironmentObject var carousel: PhotoCarousel
    @AppStorage("k62.face.position") private var positionRaw = FaceStudio.Position.bottom.rawValue
    @AppStorage("k62.face.colorHex") private var colorHex = "FFFFFF"
    @AppStorage("k62.face.glass") private var glass = true
    @AppStorage("k62.face.timeStyle") private var timeStyle = -1
    @State private var items: [PhotosPickerItem] = []
    @State private var pickNote: String?

    private var style: FaceStyle {
        FaceStyle(position: FaceStudio.Position(rawValue: positionRaw) ?? .bottom,
                  timeStyle: timeStyle, colorHex: colorHex, glass: glass)
    }

    private let intervals = [1, 3, 6, 12, 24]

    var body: some View {
        Page(title: "Fotos") {
            // The carousel timer changes displayIndex inside withAnimation, so the
            // new identity cross-fades in.
            ZStack {
                WatchPreview(image: carousel.displayImage.map { FaceStudio.compose($0, ui: watch.faceUI, style: style) },
                             round: watch.faceUI?.isRound() ?? false,
                             position: style.position, timeColor: Color(uiColor: style.color), size: 230)
                    .id(carousel.displayIndex)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
            .padding(.vertical, 12)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionTitle(text: "Carrusel", icon: "photo.stack")
                    Spacer()
                    Text("\(carousel.photos.count) fotos").font(.caption).foregroundStyle(.secondary)
                }
                if !carousel.photos.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(carousel.photos, id: \.self) { url in
                                if let img = carousel.image(url) {
                                    Image(uiImage: img).resizable().scaledToFill()
                                        .frame(width: 72, height: 72)
                                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                        .overlay(alignment: .topTrailing) {
                                            Button { withAnimation { carousel.remove(url) } } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .symbolRenderingMode(.palette)
                                                    .foregroundStyle(.white, .black.opacity(0.5))
                                            }
                                            .padding(4)
                                        }
                                }
                            }
                        }
                    }
                }
                PhotosPicker(selection: $items,
                             maxSelectionCount: max(1, PhotoCarousel.maxPhotos - carousel.photos.count),
                             matching: .images) {
                    Label("Añadir fotos", systemImage: "plus")
                }
                .buttonStyle(GlassButtonStyle(prominent: carousel.photos.isEmpty))
                .disabled(carousel.photos.count >= PhotoCarousel.maxPhotos)
                if let pickNote {
                    Text(pickNote).font(.caption).foregroundStyle(.orange)
                }
                Text("En la app las fotos van cambiando solas cada pocos segundos y forman el fondo. Máximo \(PhotoCarousel.maxPhotos).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .glassCard()

            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "En el reloj", icon: "applewatch")
                Picker("Modo", selection: $carousel.mode) {
                    ForEach(PhotoCarousel.Mode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                switch carousel.mode {
                case .off:
                    Text("Las fotos solo se usan en la app.").font(.caption).foregroundStyle(.secondary)
                case .album:
                    if watch.ready && !studio.albumSupported {
                        Text("Este firmware no declara álbum de fotos. Prueba «Esfera rotativa».")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button("Enviar \(carousel.photos.count) fotos al reloj") { carousel.sendAlbum() }
                        .buttonStyle(GlassButtonStyle(prominent: true))
                        .disabled(!watch.ready || studio.busy || carousel.photos.isEmpty || !studio.albumSupported)
                    Text("Usa el álbum nativo del reloj (función oficial de fotos del firmware).")
                        .font(.caption).foregroundStyle(.secondary)
                case .rotate:
                    Picker("Cambiar cada", selection: $carousel.intervalHours) {
                        ForEach(intervals, id: \.self) { Text("\($0) h").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if !studio.templateReady {
                        Text("Primero obtén la plantilla en la pestaña Esfera.").font(.caption).foregroundStyle(.orange)
                    }
                    Button("Cambiar ahora") { carousel.rotateIfDue(force: true) }
                        .buttonStyle(GlassButtonStyle(prominent: true))
                        .disabled(!watch.ready || studio.busy || carousel.photos.isEmpty || !studio.templateReady)
                    Text(carousel.nextRotationText).font(.caption).foregroundStyle(.secondary)
                    Text("La esfera usa la siguiente foto como fondo. iOS solo deja que la app trabaje en segundo plano cuando el reloj se conecta, así que el cambio ocurre al abrir la app o al reconectar tras el intervalo.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                StudioProgress()
            }
            .glassCard()
        }
        .onChange(of: items) { picked in
            guard !picked.isEmpty else { return }
            Task {
                var imgs: [UIImage] = []
                for item in picked {
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                        imgs.append(img)
                    }
                }
                await MainActor.run {
                    var skipped = 0
                    withAnimation { skipped = carousel.add(imgs) }
                    let failed = picked.count - imgs.count
                    var notes: [String] = []
                    if skipped > 0 { notes.append("\(skipped) no se añadieron: límite de \(PhotoCarousel.maxPhotos) fotos") }
                    if failed > 0 { notes.append("\(failed) no se pudieron leer") }
                    pickNote = notes.isEmpty ? nil : notes.joined(separator: " · ")
                    items = []
                }
            }
        }
    }
}

// MARK: - Avisos

struct NotifApp: Identifiable {
    let app: FitCloudNotificationApp
    let name: String
    let symbol: String
    let colors: [Color]
    var id: String { name }

    static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    static let all: [NotifApp] = [
        NotifApp(app: .call, name: "Llamadas", symbol: "phone.fill", colors: [rgb(0x34C759), rgb(0x28A745)]),
        NotifApp(app: .SMS, name: "Mensajes", symbol: "message.fill", colors: [rgb(0x5BE86F), rgb(0x30C04A)]),
        NotifApp(app: .whatsApp, name: "WhatsApp", symbol: "phone.bubble.left.fill", colors: [rgb(0x25D366), rgb(0x128C7E)]),
        NotifApp(app: .whatsAppBusiness, name: "WhatsApp Business", symbol: "briefcase.fill", colors: [rgb(0x128C7E), rgb(0x075E54)]),
        NotifApp(app: .telegram, name: "Telegram", symbol: "paperplane.fill", colors: [rgb(0x37BBFE), rgb(0x1E96C8)]),
        NotifApp(app: .teams, name: "Teams", symbol: "person.2.fill", colors: [rgb(0x7B83EB), rgb(0x4B53BC)]),
        NotifApp(app: .outlook, name: "Outlook", symbol: "envelope.open.fill", colors: [rgb(0x1E90FF), rgb(0x0A64D6)]),
        NotifApp(app: .gmail, name: "Gmail", symbol: "envelope.fill", colors: [rgb(0xEA4335), rgb(0xC5221F)]),
        NotifApp(app: .mail, name: "Correo", symbol: "envelope.fill", colors: [rgb(0x4FA3FF), rgb(0x1A73E8)]),
        NotifApp(app: .calendar, name: "Calendario", symbol: "calendar", colors: [rgb(0xFF5A5F), rgb(0xE0342F)]),
        NotifApp(app: .instagram, name: "Instagram", symbol: "camera.fill", colors: [rgb(0xF58529), rgb(0xDD2A7B), rgb(0x8134AF)]),
        NotifApp(app: .messenger, name: "Messenger", symbol: "bolt.fill", colors: [rgb(0x00B2FF), rgb(0xA033FF)]),
        NotifApp(app: .facebook, name: "Facebook", symbol: "f.cursive", colors: [rgb(0x3B8BFF), rgb(0x1877F2)]),
        NotifApp(app: .other, name: "Otras apps", symbol: "square.grid.2x2.fill", colors: [rgb(0x9AA0A6), rgb(0x5F6368)]),
    ]
}

struct AppIcon: View {
    let item: NotifApp
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(LinearGradient(colors: item.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 36, height: 36)
            .overlay(Image(systemName: item.symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .shadow(color: (item.colors.last ?? .black).opacity(0.35), radius: 6, y: 3)
    }
}

struct AlertsView: View {
    @EnvironmentObject var watch: Watch
    @State private var selection: Set<FitCloudNotificationApp> = []

    /// How an app reaches the watch: its own category (own icon), through
    /// "Otras apps" (generic icon), or not at all on this firmware.
    private enum Route { case unknown, own, viaOther, unavailable }

    private func route(_ item: NotifApp) -> Route {
        guard watch.ready else { return .unknown }
        if watch.supports(item.app) { return .own }
        return watch.supports(.other) ? .viaOther : .unavailable
    }

    private func detail(_ r: Route) -> String {
        switch r {
        case .unknown: return "Conecta el reloj para ver cómo llega"
        case .own: return "Icono propio en el reloj"
        case .viaOther: return "Llega como «Otras apps» (icono genérico)"
        case .unavailable: return "Este firmware no lo muestra"
        }
    }

    private func key(_ item: NotifApp) -> FitCloudNotificationApp {
        route(item) == .viaOther ? .other : item.app
    }

    var body: some View {
        Page(title: "Avisos") {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "Modo minimalista", icon: "sparkles")
                Text("El reloj solo vibra con lo importante.").font(.caption).foregroundStyle(.secondary)
                Button("Llamadas, mensajes, WhatsApp y Teams") {
                    var s: Set<FitCloudNotificationApp> = [.call, .SMS, .whatsApp]
                    if let teams = NotifApp.all.first(where: { $0.app == .teams }), route(teams) != .unavailable {
                        s.insert(key(teams))
                    }
                    selection = s
                    watch.setApps(s)
                }
                .buttonStyle(GlassButtonStyle(prominent: true))
                .disabled(!watch.ready)
            }
            .glassCard()

            VStack(spacing: 0) {
                ForEach(NotifApp.all) { item in
                    let r = route(item)
                    HStack(spacing: 14) {
                        AppIcon(item: item)
                            .saturation(r == .unavailable ? 0 : 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.subheadline.weight(.medium))
                            Text(detail(r))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { selection.contains(key(item)) },
                            set: { on in
                                if on { selection.insert(key(item)) } else { selection.remove(key(item)) }
                                watch.setApps(selection)
                            }))
                            .labelsHidden()
                            .tint(item.colors.first ?? Palette.mint)
                            .disabled(r == .unavailable || r == .unknown)
                    }
                    .padding(.vertical, 9)
                    if item.id != NotifApp.all.last?.id {
                        Divider().opacity(0.4).padding(.leading, 50)
                    }
                }
            }
            .glassCard(padding: 16)

            Text("Los iconos y el diseño de los avisos en la pantalla del reloj están dentro del firmware del K62; el SDK oficial no permite cambiarlos. Las apps sin categoría propia, como Teams en este firmware, llegan con el icono genérico.")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 6)

            Text("En el iPhone: Ajustes › Notificaciones › Mostrar previsualizaciones = Siempre, para que llegue el texto completo.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 6)
        }
        .onAppear { selection = watch.enabledApps }
        .onChange(of: watch.enabledApps) { selection = $0 }
    }
}

// MARK: - WhatsApp

struct WhatsAppView: View {
    @EnvironmentObject var watch: Watch
    @State private var speech: Bool?

    var body: some View {
        Page(title: "WhatsApp") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionTitle(text: "Compatibilidad", icon: "checkmark.shield")
                    Spacer()
                    Chip(text: watch.ready ? (watch.supportsWhatsApp ? "Compatible" : "No compatible") : "—",
                         on: watch.supportsWhatsApp)
                }
                Text("Con firmware compatible, el complemento oficial permite leer chats completos y responder desde el reloj con texto, voz dictada o imágenes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .glassCard()

            if watch.supportsWhatsApp {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(text: "Respuestas por voz", icon: "mic")
                    Button("Preparar dictado") {
                        FitCloudWhatsApp.setAppLanguage("es")
                        FitCloudWhatsApp.requestSpeechAuthorization { ok in
                            DispatchQueue.main.async { speech = ok }
                        }
                    }
                    .buttonStyle(GlassButtonStyle(prominent: true))
                    if let speech {
                        Text(speech ? "Dictado autorizado" : "Dictado denegado en Ajustes").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Abre WhatsApp en el reloj. Si muestra un QR, escanéalo desde WhatsApp › Ajustes › Dispositivos vinculados en este iPhone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .glassCard()
            } else if watch.ready {
                Text("El firmware \(watch.firmware) no declara soporte. Los avisos de WhatsApp siguen llegando por iOS (pestaña Avisos).")
                    .font(.caption).foregroundStyle(.secondary)
                    .glassCard()
            }
        }
    }
}
