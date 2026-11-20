import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import FitCloudKit
import FitCloudWhatsApp

struct RootView: View {
    var body: some View {
        TabView {
            WatchView().tabItem { Label("Reloj", systemImage: "applewatch") }
            FaceView().tabItem { Label("Esfera", systemImage: "circle.dashed") }
            AlertsView().tabItem { Label("Avisos", systemImage: "bell") }
            WhatsAppView().tabItem { Label("WhatsApp", systemImage: "message") }
        }
    }
}

// MARK: - Reloj

struct WatchView: View {
    @EnvironmentObject var watch: Watch

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Circle().fill(watch.ready ? Color.green : watch.connected ? Color.orange : Color.gray)
                            .frame(width: 10, height: 10)
                        Text(watch.status)
                    }
                    row("Bluetooth", watch.bluetooth)
                    if watch.ready {
                        row("Batería", watch.battery.map { "\($0)%" } ?? "—")
                        row("Firmware", watch.firmware)
                    }
                }

                if !watch.connected {
                    Section {
                        Button(watch.scanning ? "Buscando…" : "Buscar K62") { watch.scan() }
                            .disabled(watch.scanning)
                        ForEach(watch.devices) { d in
                            Button {
                                watch.bind(d)
                            } label: {
                                HStack {
                                    Text(d.name)
                                    Spacer()
                                    Text(d.rssi.map { "\($0) dBm" } ?? "conectado a iOS")
                                        .foregroundStyle(.secondary).font(.caption)
                                }
                            }
                        }
                    } footer: {
                        Text("Al tocar el K62 esta app se vincula al reloj (confírmalo en la pantalla del reloj) y empareja el Bluetooth clásico para llamadas y música. FitCloudPro dejará de estar vinculado.")
                    }
                } else {
                    Section {
                        Button("Desconectar", role: .destructive) { watch.disconnect() }
                    }
                }

                if !watch.capabilities.isEmpty {
                    Section("Lo que este firmware permite") {
                        ForEach(watch.capabilities) { c in
                            HStack {
                                Text(c.name)
                                Spacer()
                                Text(c.value).foregroundStyle(c.good ? .primary : .secondary)
                            }
                        }
                    }
                }

                Section("Registro") {
                    ForEach(Array(watch.log.prefix(40).enumerated()), id: \.offset) { item in
                        Text(item.element).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("K62 Minimal")
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v) }
    }
}

// MARK: - Esfera

struct FaceView: View {
    @EnvironmentObject var watch: Watch
    @EnvironmentObject var studio: FaceStudio
    @State private var design = "2-orbita"
    @State private var custom: UIImage?
    @State private var pick: PhotosPickerItem?
    @State private var position = FaceStudio.Position.top
    @State private var amber = false
    @State private var importing = false
    @State private var confirm = false

    private var background: UIImage? {
        custom ?? FaceStudio.background(design, for: watch.faceUI)
    }

    private var color: UIColor {
        amber ? UIColor(red: 1, green: 0.84, blue: 0.63, alpha: 1) : .white
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Spacer()
                        if let bk = background {
                            Image(uiImage: FaceStudio.preview(bk: bk, ui: watch.faceUI, position: position, color: color))
                                .resizable().scaledToFit().frame(height: 220)
                                .clipShape(RoundedRectangle(cornerRadius: (watch.faceUI?.isRound() ?? true) ? 110 : 36))
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                Section("Diseño") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(FaceStudio.designs, id: \.self) { d in
                                if let img = FaceStudio.background(d, for: watch.faceUI) {
                                    Image(uiImage: img).resizable().scaledToFit().frame(width: 64, height: 64)
                                        .clipShape(Circle())
                                        .overlay(Circle().stroke(design == d && custom == nil ? Color.accentColor : .clear, lineWidth: 2))
                                        .onTapGesture { design = d; custom = nil; amber = d.contains("ambar") }
                                }
                            }
                        }
                    }
                    PhotosPicker("Usar una foto propia", selection: $pick, matching: .images)
                    Picker("Hora", selection: $position) {
                        ForEach(FaceStudio.Position.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Hora en ámbar", isOn: $amber)
                }

                Section {
                    if studio.templateReady {
                        Label("Plantilla del reloj lista", systemImage: "checkmark.circle")
                    } else {
                        Button("Obtener plantilla del reloj") {
                            if let ui = watch.faceUI { studio.fetchTemplate(ui: ui) }
                        }
                        .disabled(watch.faceUI == nil)
                        Button("Importar plantilla .bin…") { importing = true }
                    }
                    Button(studio.busy ? "Instalando…" : "Instalar en el reloj") { confirm = true }
                        .disabled(!watch.ready || !studio.templateReady || studio.busy || background == nil)
                    if studio.busy || studio.progress > 0 {
                        ProgressView(value: studio.progress)
                    }
                    if !studio.message.isEmpty {
                        Text(studio.message).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Instalar")
                } footer: {
                    Text("Usa la vía oficial del fabricante (FitCloudWFKit + OTA/DFU). Una plantilla que no corresponda al modelo puede dejar la esfera o el reloj inservibles.")
                }

                if let slots = watch.faceUI?.slots, !slots.isEmpty {
                    Section("Esferas en el reloj") {
                        ForEach(slots, id: \.slotIndex) { s in
                            HStack {
                                Text("Ranura \(s.slotIndex) · nº \(s.watchfaceNo)")
                                Spacer()
                                Button("Mostrar") { watch.showFace(slot: Int(s.slotIndex)) }.buttonStyle(.borderless)
                                if s.slotType.rawValue != 0 {
                                    Button("Borrar", role: .destructive) { watch.deleteFace(slot: Int(s.slotIndex)) }.buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Esfera")
            .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "bin") ?? .data, .data]) { result in
                if case .success(let url) = result { studio.importTemplate(from: url) }
            }
            .onChange(of: pick) { item in
                Task {
                    if let data = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                        custom = img
                    }
                }
            }
            .confirmationDialog("¿Instalar esta esfera en el K62?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Instalar") {
                    if let bk = background { studio.install(bk: bk, ui: watch.faceUI, position: position, color: color) }
                }
            } message: {
                Text("El reloj entrará en modo de actualización durante la transferencia. No lo alejes del iPhone.")
            }
        }
    }
}

// MARK: - Avisos

struct AlertsView: View {
    @EnvironmentObject var watch: Watch
    @State private var selection: Set<FitCloudNotificationApp> = []

    private let apps: [(FitCloudNotificationApp, String)] = [
        (.call, "Llamadas"), (.SMS, "Mensajes"), (.whatsApp, "WhatsApp"),
        (.whatsAppBusiness, "WhatsApp Business"), (.telegram, "Telegram"), (.mail, "Correo"),
        (.gmail, "Gmail"), (.outlook, "Outlook"), (.calendar, "Calendario"), (.teams, "Teams"),
        (.instagram, "Instagram"), (.messenger, "Messenger"), (.facebook, "Facebook"), (.other, "Otras apps"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Solo lo esencial: llamadas, mensajes y WhatsApp") {
                        selection = [.call, .SMS, .whatsApp]
                        watch.setApps(selection)
                    }
                } footer: {
                    Text("El reloj solo vibrará con las apps activadas. iOS además debe mostrar previsualizaciones «Siempre» para que llegue el texto completo.")
                }
                Section("Apps que avisan en el reloj") {
                    ForEach(apps, id: \.1) { item in
                        if watch.supports(item.0) {
                            Toggle(item.1, isOn: Binding(
                                get: { selection.contains(item.0) },
                                set: { on in
                                    if on { selection.insert(item.0) } else { selection.remove(item.0) }
                                    watch.setApps(selection)
                                }))
                        }
                    }
                }
            }
            .disabled(!watch.ready)
            .navigationTitle("Avisos")
            .onAppear { selection = watch.enabledApps }
            .onChange(of: watch.enabledApps) { selection = $0 }
        }
    }
}

// MARK: - WhatsApp

struct WhatsAppView: View {
    @EnvironmentObject var watch: Watch
    @State private var speech: Bool?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Firmware compatible")
                        Spacer()
                        Text(watch.ready ? (watch.supportsWhatsApp ? "Sí" : "No") : "—")
                            .foregroundStyle(watch.supportsWhatsApp ? Color.green : Color.secondary)
                    }
                } footer: {
                    Text("Con firmware compatible, el complemento oficial FitCloudWhatsApp permite leer chats completos y responder desde el reloj con texto, voz dictada o imágenes, vinculando WhatsApp como dispositivo enlazado.")
                }
                if watch.supportsWhatsApp {
                    Section {
                        Button("Preparar respuestas por voz") {
                            FitCloudWhatsApp.setAppLanguage("es")
                            FitCloudWhatsApp.requestSpeechAuthorization { ok in
                                DispatchQueue.main.async { speech = ok }
                            }
                        }
                        if let speech {
                            Text(speech ? "Dictado autorizado" : "Dictado denegado en Ajustes").foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("Abre WhatsApp en el reloj. Si muestra un código QR, escanéalo desde WhatsApp › Ajustes › Dispositivos vinculados en este iPhone. Mantén esta app abierta en segundo plano.")
                    }
                } else if watch.ready {
                    Section {
                        Text("El firmware \(watch.firmware) de este K62 no declara soporte de WhatsApp. Las notificaciones de WhatsApp siguen llegando por iOS (pestaña Avisos), pero responder requiere un firmware compatible.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("WhatsApp")
        }
    }
}
