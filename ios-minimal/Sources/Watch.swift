import Foundation
import CoreBluetooth
import UIKit
import FitCloudKit

/// Wraps the official FitCloudKit SDK (htangsmart/FitCloudPro-SDK-iOS).
/// This app replaces FitCloudPro as the K62 companion: one app bound to the watch.
final class Watch: NSObject, ObservableObject {
    static let shared = Watch()

    struct Device: Identifiable {
        let id: UUID
        let name: String
        let rssi: Int?          // nil = already connected to iOS (not advertising)
        let peripheral: CBPeripheral
    }

    struct Capability: Identifiable {
        let id = UUID()
        let name: String
        let value: String
        let good: Bool
    }

    @Published var status = "Iniciando…"
    @Published var bluetooth = "—"
    @Published var devices: [Device] = []
    @Published var scanning = false
    @Published var connected = false
    @Published var ready = false
    @Published var battery: Int?
    @Published var firmware = "—"
    @Published var capabilities: [Capability] = []
    @Published var faceUI: FitCloudWatchfaceUIInfo?
    @Published var enabledApps: Set<FitCloudNotificationApp> = []
    @Published var supportsWhatsApp = false
    @Published var log: [String] = []

    /// Numeric user id kept on this phone; the watch accepts sessions only for it.
    var userId: String {
        if let id = UserDefaults.standard.string(forKey: "k62.userId") { return id }
        let id = String(UInt64.random(in: 100_000_000...999_999_999))
        UserDefaults.standard.set(id, forKey: "k62.userId")
        return id
    }

    /// Own Core Bluetooth central: asks for the Bluetooth permission at launch and
    /// finds a K62 that iOS already keeps connected (it then stops advertising).
    private var central: CBCentralManager?
    private var systemConnected: [UUID: Device] = [:]
    private static let k62Services = [CBUUID(string: "FEE7"),
                                      CBUUID(string: "000001FF-3C17-D293-8E48-14FE2E4DA212")]

    private override init() { super.init() }

    func start() {
        central = CBCentralManager(delegate: self, queue: .main)
        let option = FitCloudOption()
        option.debugMode = false
        option.shouldAutoReconnectWhenAppLaunch = true
        option.includeTimestampInLogs = false
        option.preferWriteWithoutResponse = true
        _ = FitCloudKit.initWith(option, callback: self)
        observe()
        note("SDK FitCloudKit \(FitCloudKit.sdkVersion())")
        status = FitCloudKit.isConnected() ? "Conectado" : "Desconectado"
    }

    // MARK: Events

    private func observe() {
        let c = NotificationCenter.default
        func on(_ name: String, _ handler: @escaping (Notification) -> Void) {
            c.addObserver(forName: Notification.Name(name), object: nil, queue: .main, using: handler)
        }
        on(FITCLOUDEVENT_PERIPHERAL_DISCOVERED_NOTIFY) { [weak self] _ in self?.refreshDevices() }
        on(FITCLOUDEVENT_PERIPHERAL_DISCOVERED_UPDATED_NOTIFY) { [weak self] _ in self?.refreshDevices() }
        on(FITCLOUDEVENT_PERIPHERAL_SCANSTOP_NOTIFY) { [weak self] _ in self?.scanning = false }
        on(FITCLOUDEVENT_PERIPHERAL_CONNECTING_NOTIFY) { [weak self] _ in self?.set("Conectando…") }
        on(FITCLOUDEVENT_PERIPHERAL_CONNECTED_NOTIFY) { [weak self] _ in
            self?.connected = true
            self?.set("Conectado, iniciando sesión…")
        }
        on(FITCLOUDEVENT_PERIPHERAL_CONNECT_FAILURE_NOTIFY) { [weak self] _ in self?.set("No se pudo conectar") }
        on(FITCLOUDEVENT_PERIPHERAL_DISCONNECT_NOTIFY) { [weak self] _ in
            self?.connected = false
            self?.ready = false
            self?.set("Desconectado")
        }
        on(FITCLOUDEVENT_BINDUSEROBJECT_BEGIN_NOTIFY) { [weak self] _ in self?.set("Confirma la vinculación en el reloj") }
        on(FITCLOUDEVENT_BINDUSEROBJECT_RESULT_NOTIFY) { [weak self] n in
            let ok = (n.userInfo?["result"] as? Bool) ?? false
            self?.set(ok ? "Vinculado" : "Vinculación rechazada o fallida")
            if let audio = n.userInfo?["audioBluetooth"] as? String { self?.note("Audio clásico: \(audio)") }
        }
        on(FITCLOUDEVENT_LOGINUSEROBJECT_RESULT_NOTIFY) { [weak self] n in
            let ok = (n.userInfo?["result"] as? Bool) ?? false
            self?.set(ok ? "Sesión iniciada" : "Login rechazado")
        }
        on(FITCLOUDEVENT_PERIPHERAL_ALREADYUNBUND_OR_BIND_BY_OTHERCLIENT_NOTIFY) { [weak self] _ in
            self?.set("El reloj está vinculado a otra app (FitCloudPro). Vuelve a vincular aquí.")
        }
        on(FITCLOUDEVENT_PREPARESYNCWORK_END_NOTIFY) { [weak self] _ in
            self?.ready = true
            self?.set("Listo")
            self?.loadAll()
        }
        on(FITCLOUDEVENT_BATTERYINFO_NOTIFY) { [weak self] n in
            if let b = n.object as? FitCloudBatteryInfoObject { self?.battery = Int(b.percent) }
        }
    }

    // MARK: Scan / connect

    func scan() {
        devices = []
        systemConnected = [:]
        scanning = true
        recoverSystemConnected()
        FitCloudKit.startScan()
        set("Buscando relojes…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            if self?.scanning == true { self?.stopScan() }
        }
    }

    func stopScan() {
        FitCloudKit.stopScan()
        scanning = false
    }

    private func refreshDevices() {
        var all = systemConnected
        for fc in FitCloudKit.discoveredDevices() {
            let p: CBPeripheral = fc.peripheral
            all[p.identifier] = Device(id: p.identifier, name: p.name ?? "Sin nombre",
                                       rssi: fc.rssi?.intValue ?? -127, peripheral: p)
        }
        devices = all.values.sorted { a, b in
            let ka = a.name.uppercased().hasPrefix("K62"), kb = b.name.uppercased().hasPrefix("K62")
            return ka != kb ? ka : (a.rssi ?? 0) > (b.rssi ?? 0)
        }
    }

    /// A K62 already connected to iOS (ANCS / audio) does not advertise, so a
    /// normal scan misses it. Retrieve it and let the SDK make it connectable.
    private func recoverSystemConnected() {
        guard let central, central.state == .poweredOn else {
            note("Bluetooth no listo: \(bluetooth)")
            return
        }
        let found = central.retrieveConnectedPeripherals(withServices: Self.k62Services)
        note("Conectados a iOS con servicios del K62: \(found.count)")
        for p in found {
            FitCloudKit.resolveConnectablePeripheral(from: p) { [weak self] ok, err, cp in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard ok, let cp else {
                        self.note("No se pudo preparar \(p.name ?? "reloj"): \(err?.localizedDescription ?? "-")")
                        return
                    }
                    self.systemConnected[cp.identifier] = Device(id: cp.identifier, name: cp.name ?? p.name ?? "K62",
                                                                 rssi: nil, peripheral: cp)
                    self.refreshDevices()
                }
            }
        }
    }

    /// Binds this app to the watch and pairs Bluetooth Classic (calls + music) in one step.
    func bind(_ d: Device) {
        stopScan()
        note("Vinculando \(d.name) con usuario local")
        FitCloudKit.connectAndBind(d.peripheral, userId: userId, randomCode: nil, withClassicBT: true)
    }

    func disconnect() {
        FitCloudKit.disconnect()
    }

    // MARK: Read state

    func loadAll() {
        guard let cfg = FitCloudKit.allConfig() else { return }
        if let fw = cfg.firmware {
            let version: String? = fw.firmwareVersion
            firmware = version ?? "—"
            supportsWhatsApp = fw.supportsWhatsApp
            let hw = UInt64(fw.hardwareSupported.rawValue)
            let platform = hw & (1 << 26) != 0 ? "gui-8773" : hw & (1 << 27) != 0 ? "gui-5681" : "gui"
            capabilities = [
                Capability(name: "WhatsApp (leer y responder)", value: fw.supportsWhatsApp ? "Sí" : "No", good: fw.supportsWhatsApp),
                Capability(name: "Esfera DIY + subida", value: yes(FitCloudKit.isDeviceSupport(.WATCHFACEDIYANDOTA)), good: FitCloudKit.isDeviceSupport(.WATCHFACEDIYANDOTA)),
                Capability(name: "Subir esferas", value: yes(FitCloudKit.isDeviceSupport(.WATCHFACEOTA)), good: FitCloudKit.isDeviceSupport(.WATCHFACEOTA)),
                Capability(name: "Arquitectura GUI nueva", value: yes(fw.isNewGUIArchitecture), good: true),
                Capability(name: "OTA nuevo", value: yes(fw.withNewOTA), good: true),
                Capability(name: "Plataforma", value: platform, good: true),
            ]
            note("Firmware \(firmware) · WhatsApp=\(fw.supportsWhatsApp)")
        }
        enabledApps = cfg.enabledNotificationApps
        FitCloudKit.getBatteryInfo { [weak self] ok, info, _ in
            DispatchQueue.main.async { if ok, let info { self?.battery = Int(info.percent) } }
        }
        FitCloudKit.getWatchfaceUIInformation { [weak self] ok, ui, err in
            DispatchQueue.main.async {
                guard ok, let ui else { self?.note("Info de esfera no disponible: \(err?.localizedDescription ?? "-")"); return }
                self?.faceUI = ui
                let r = ui.screenResolution()
                self?.capabilities.append(Capability(name: "Pantalla", value: "\(Int(r.width))×\(Int(r.height)) \(ui.isRound() ? "redonda" : "rectangular") (lcd \(ui.lcd))", good: true))
                let tool: String? = ui.toolVersion
                let slots: [FitCloudWatchfaceSlot]? = ui.slots
                self?.capabilities.append(Capability(name: "Herramienta de esferas", value: tool ?? "?", good: true))
                self?.capabilities.append(Capability(name: "Ranuras de esfera", value: "\(slots?.count ?? 0)", good: true))
            }
        }
    }

    // MARK: Notifications (which apps may buzz the watch)

    func setApps(_ apps: Set<FitCloudNotificationApp>) {
        FitCloudKit.setEnabledNotificationApps(apps) { [weak self] ok, err in
            DispatchQueue.main.async {
                if ok { self?.enabledApps = apps; self?.note("Avisos actualizados (\(apps.count) apps)") }
                else { self?.note("No se pudieron guardar los avisos: \(err?.localizedDescription ?? "-")") }
            }
        }
    }

    func supports(_ app: FitCloudNotificationApp) -> Bool {
        FitCloudKit.isDeviceSupportNotificationApp(app)
    }

    // MARK: Watch faces on the watch

    func showFace(slot: Int) {
        FitCloudKit.toggleWatchface(withSlotIndex: slot, modulesStyleArray: nil) { [weak self] ok, err in
            DispatchQueue.main.async { self?.note(ok ? "Esfera \(slot) activa" : "No se pudo cambiar: \(err?.localizedDescription ?? "-")") }
        }
    }

    func deleteFace(slot: Int) {
        FitCloudKit.deleteWatchface(withSlotIndex: slot) { [weak self] ok, err in
            DispatchQueue.main.async {
                self?.note(ok ? "Esfera \(slot) borrada" : "No se pudo borrar: \(err?.localizedDescription ?? "-")")
                self?.loadAll()
            }
        }
    }

    // MARK: Helpers

    private func yes(_ b: Bool) -> String { b ? "Sí" : "No" }

    func set(_ s: String) {
        status = s
        note(s)
    }

    func note(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log.insert("\(f.string(from: Date())) \(s)", at: 0)
        if log.count > 200 { log.removeLast() }
    }
}

extension Watch: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch CBManager.authorization {
        case .denied, .restricted:
            bluetooth = "Permiso denegado: Ajustes › K62 Minimal › Bluetooth"
        default:
            switch central.state {
            case .poweredOn: bluetooth = "Activo"
            case .poweredOff: bluetooth = "Apagado en el iPhone"
            case .unauthorized: bluetooth = "Sin permiso"
            default: bluetooth = "No disponible"
            }
        }
        note("Bluetooth: \(bluetooth)")
    }
}

extension Watch: FitCloudCallback {
    func onFindiPhoneEvent() {
        DispatchQueue.main.async { self.note("El reloj busca el iPhone") }
    }
}
