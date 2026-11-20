import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import FitCloudKit
import FitCloudWhatsApp

struct RootView: View {
    var body: some View {
        TabView {
            HomeView().tabItem { Label("Reloj", systemImage: "applewatch") }
            FaceView().tabItem { Label("Esfera", systemImage: "circle.hexagongrid") }
            PhotosView().tabItem { Label("Fotos", systemImage: "photo.stack") }
            AlertsView().tabItem { Label("Avisos", systemImage: "bell.badge") }
            WhatsAppView().tabItem { Label("WhatsApp", systemImage: "bubble.left.and.text.bubble.right") }
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
            WatchPreview(image: carousel.displayImage ?? FaceStudio.background(design, for: watch.faceUI),
                         round: watch.faceUI?.isRound() ?? true, size: 118)
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
    @AppStorage("k62.face.position") private var positionRaw = 0
    @AppStorage("k62.face.amber") private var amber = false
    @State private var custom: UIImage?
    @State private var pick: PhotosPickerItem?
    @State private var importing = false
    @State private var confirm = false

    private var position: FaceStudio.Position { FaceStudio.Position(rawValue: positionRaw) ?? .top }
    private var background: UIImage? { custom ?? FaceStudio.background(design, for: watch.faceUI) }
    private var color: UIColor { amber ? UIColor(red: 1, green: 0.84, blue: 0.63, alpha: 1) : .white }
    private var round: Bool { watch.faceUI?.isRound() ?? true }

    var body: some View {
        Page(title: "Esfera") {
            WatchPreview(image: background, round: round, position: position, amber: amber, size: 230)
                .padding(.vertical, 12)

            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "Diseño", icon: "paintbrush")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(FaceStudio.designs, id: \.self) { d in
                            if let img = FaceStudio.background(d, for: watch.faceUI) {
                                Image(uiImage: img).resizable().scaledToFill()
                                    .frame(width: 60, height: 60)
                                    .clipShape(Circle())
                                    .overlay(Circle().strokeBorder(design == d && custom == nil ? Palette.mint : Color.white.opacity(0.2),
                                                                   lineWidth: design == d && custom == nil ? 3 : 1))
                                    .onTapGesture {
                                        withAnimation(.spring()) { design = d; custom = nil; amber = d.contains("ambar") }
                                    }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                PhotosPicker(selection: $pick, matching: .images) {
                    Label("Usar una foto propia", systemImage: "photo")
                }
                .buttonStyle(GlassButtonStyle())
                Picker("Hora", selection: $positionRaw) {
                    ForEach(FaceStudio.Position.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Toggle("Hora en ámbar", isOn: $amber)
            }
            .glassCard()

            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "Instalar", icon: "square.and.arrow.down.on.square")
                if studio.templateReady {
                    Label("Plantilla del reloj lista", systemImage: "checkmark.seal.fill").foregroundStyle(Palette.mint)
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
                if let bk = background { studio.install(bk: bk, ui: watch.faceUI, position: position, color: color) }
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
    @AppStorage("k62.face.position") private var positionRaw = 0
    @AppStorage("k62.face.amber") private var amber = false
    @State private var items: [PhotosPickerItem] = []

    private let intervals = [1, 3, 6, 12, 24]

    var body: some View {
        Page(title: "Fotos") {
            WatchPreview(image: carousel.displayImage, round: watch.faceUI?.isRound() ?? true,
                         position: FaceStudio.Position(rawValue: positionRaw) ?? .top, amber: amber, size: 230)
                .id(carousel.displayIndex)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .animation(.easeInOut(duration: 0.8), value: carousel.displayIndex)
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
                PhotosPicker(selection: $items, maxSelectionCount: 12, matching: .images) {
                    Label("Añadir fotos", systemImage: "plus")
                }
                .buttonStyle(GlassButtonStyle(prominent: carousel.photos.isEmpty))
                Text("En la app las fotos van cambiando solas cada pocos segundos y forman el fondo.")
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
                    withAnimation { carousel.add(imgs) }
                    items = []
                }
            }
        }
    }
}

// MARK: - Avisos

struct AlertsView: View {
    @EnvironmentObject var watch: Watch
    @State private var selection: Set<FitCloudNotificationApp> = []

    private let apps: [(FitCloudNotificationApp, String, String)] = [
        (.call, "Llamadas", "phone.fill"), (.SMS, "Mensajes", "message.fill"),
        (.whatsApp, "WhatsApp", "bubble.left.fill"), (.whatsAppBusiness, "WhatsApp Business", "briefcase.fill"),
        (.telegram, "Telegram", "paperplane.fill"), (.mail, "Correo", "envelope.fill"),
        (.gmail, "Gmail", "envelope.badge.fill"), (.outlook, "Outlook", "tray.fill"),
        (.calendar, "Calendario", "calendar"), (.teams, "Teams", "person.3.fill"),
        (.instagram, "Instagram", "camera.fill"), (.messenger, "Messenger", "bolt.horizontal.circle.fill"),
        (.facebook, "Facebook", "f.circle.fill"), (.other, "Otras apps", "ellipsis.circle.fill"),
    ]

    var body: some View {
        Page(title: "Avisos") {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "Modo minimalista", icon: "sparkles")
                Text("El reloj solo vibra con lo importante.").font(.caption).foregroundStyle(.secondary)
                Button("Solo llamadas, mensajes y WhatsApp") {
                    selection = [.call, .SMS, .whatsApp]
                    watch.setApps(selection)
                }
                .buttonStyle(GlassButtonStyle(prominent: true))
            }
            .glassCard()

            VStack(spacing: 0) {
                ForEach(apps.filter { watch.supports($0.0) }, id: \.1) { item in
                    Toggle(isOn: Binding(
                        get: { selection.contains(item.0) },
                        set: { on in
                            if on { selection.insert(item.0) } else { selection.remove(item.0) }
                            watch.setApps(selection)
                        })) {
                        Label(item.1, systemImage: item.2)
                    }
                    .tint(Palette.mint)
                    .padding(.vertical, 10)
                }
            }
            .glassCard(padding: 16)

            Text("En el iPhone: Ajustes › Notificaciones › Mostrar previsualizaciones = Siempre, para que llegue el texto completo.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 6)
        }
        .disabled(!watch.ready)
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
