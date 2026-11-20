import Foundation
import UIKit
import FitCloudKit
import FitCloudDFUKit
import FitCloudWFKit

/// Builds a DIY watch face (own background + time) with FitCloudWFKit and
/// installs it on the K62 through the official OTA/DFU path (silent UI DFU).
final class FaceStudio: NSObject, ObservableObject {
    static let shared = FaceStudio()

    enum Position: Int, CaseIterable, Identifiable {
        case top, bottom, left, right
        var id: Int { rawValue }
        var label: String { ["Arriba", "Abajo", "Izquierda", "Derecha"][rawValue] }
        var sdk: FITCLOUDWATCHFACEDTPOSITION { [.TOP, .BOTTOM, .LEFT, .RIGHT][rawValue] }
    }

    @Published var busy = false
    @Published var progress: Double = 0
    @Published var message = ""
    @Published var templateReady = FileManager.default.fileExists(atPath: FaceStudio.templateURL.path)

    static let templateURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("k62-diy-template.bin")

    /// Transfer state. Only touched on the main thread (SDK callbacks hop via onMain).
    private var queue: [String] = []
    private var total = 0
    private var waitingForReconnect = false
    private var finishHandler: ((Bool) -> Void)?
    private var lastActivity = Date()
    private var watchdog: Timer?
    /// A transfer with no progress for this long is considered stuck.
    private static let stallTimeout: TimeInterval = 240

    private override init() {
        super.init()
        FitCloudDFUKit.setDelegate(self)
        NotificationCenter.default.addObserver(forName: Notification.Name(FITCLOUDEVENT_PERIPHERAL_RECONNECTEDWITHDFUMODE_NOTIFY),
                                               object: nil, queue: .main) { [weak self] _ in
            self?.say("El reloj volvió en modo DFU; saliendo del modo DFU")
            FitCloudKit.exitDFUMode { _, _ in }
        }
        // After a DFU transfer the watch reconnects; continue with the next file.
        NotificationCenter.default.addObserver(forName: Notification.Name(FITCLOUDEVENT_PREPARESYNCWORK_END_NOTIFY),
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, self.waitingForReconnect else { return }
            self.waitingForReconnect = false
            self.touch()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.pushNext() }
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// Marks the start of a transfer job; refuses if another one is running.
    private func begin(_ onFinish: ((Bool) -> Void)?) -> Bool {
        guard !busy else { say("Ya hay una transferencia en curso"); return false }
        busy = true
        progress = 0
        finishHandler = onFinish
        touch()
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self, self.busy else { return }
            if Date().timeIntervalSince(self.lastActivity) > Self.stallTimeout {
                self.fail("La transferencia no avanza; cancelada. Acerca el reloj e inténtalo de nuevo.")
                FitCloudDFUKit.abortIfNeeded()
                if FitCloudKit.isCurrentDFUMode() { FitCloudKit.exitDFUMode { _, _ in } }
            }
        }
        return true
    }

    private func touch() { lastActivity = Date() }

    // MARK: Photo album (native watch feature)

    var albumSupported: Bool {
        FitCloudKit.allConfig()?.firmware?.allowPhotoPush == true || FitCloudKit.isDeviceSupport(.PHOTOALBUMOTA)
    }

    func sendAlbum(_ images: [UIImage]) {
        guard !images.isEmpty else { say("Añade fotos primero"); return }
        guard albumSupported else { say("Este firmware no declara álbum de fotos"); return }
        guard begin(nil) else { return }
        say("Preparando \(images.count) fotos…")
        FitCloudKit.getPhotoPushParams { [weak self] ok, params, err in
            guard let self else { return }
            guard ok, let params else { self.fail("Parámetros de álbum no disponibles: \(err?.localizedDescription ?? "-")"); return }
            let p = DevicePhotoCreateParams()
            p.isRound = params.isRound
            p.width = params.width
            p.height = params.height
            p.cornerRadius = params.cornerRadius
            p.previewWidth = params.previewWidth
            p.previewHeight = params.previewHeight
            p.previewCornerRadius = params.previewCornerRadius
            p.photoAlbumPreviewWidth = params.photoAlbumPreviewWidth
            p.photoAlbumPreviewHeight = params.photoAlbumPreviewHeight
            p.photoAlbumPreviewCornerRadius = params.photoAlbumPreviewCornerRadius
            self.makePhotoBins(images, params: p, done: [], index: 0)
        }
    }

    private func makePhotoBins(_ images: [UIImage], params: DevicePhotoCreateParams, done: [String], index: Int) {
        guard index < images.count else {
            if done.isEmpty { fail("No se pudo convertir ninguna foto") } else { onMain { self.push(done) } }
            return
        }
        onMain { self.touch() }
        say("Convirtiendo foto \(index + 1) de \(images.count)…")
        FitCloudWFKit.createPhotoBin(with: images[index], parameters: params, logging: nil) { [weak self] ok, path, err in
            guard let self else { return }
            var acc = done
            if ok, let path {
                // Keep a private copy: the SDK may reuse its output path.
                let dst = FileManager.default.temporaryDirectory.appendingPathComponent("k62-photo-\(index).bin")
                try? FileManager.default.removeItem(at: dst)
                if (try? FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: dst)) != nil {
                    acc.append(dst.path)
                }
            } else {
                self.say("Foto \(index + 1) omitida: \(err?.localizedDescription ?? "-")")
            }
            self.makePhotoBins(images, params: params, done: acc, index: index + 1)
        }
    }

    // MARK: Bundled minimalist backgrounds (generated by windows-minimal/tools/make_faces.py)

    static let designs = ["1-noche", "2-orbita", "3-indices", "4-horizonte", "5-eclipse", "6-ambar"]

    static func background(_ design: String, for ui: FitCloudWatchfaceUIInfo?) -> UIImage? {
        let size = ui?.screenResolution() ?? CGSize(width: 466, height: 466)
        let round = ui?.isRound() ?? true
        let folder: String
        if round { folder = size.width <= 456 ? "454" : "466" }
        else { folder = size.width <= 300 ? "240x284" : "410x502" }
        return UIImage(named: "face_\(folder)_\(design)")
    }

    /// Preview the watch shows in its face list: background + a sample time.
    static func preview(bk: UIImage, ui: FitCloudWatchfaceUIInfo?, position: Position, color: UIColor) -> UIImage {
        let size = ui?.screenResolution() ?? bk.size
        let round = ui?.isRound() ?? false
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            if round { UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).addClip() }
            bk.draw(in: CGRect(origin: .zero, size: size))
            let font = UIFont.systemFont(ofSize: size.width * 0.2, weight: .thin)
            let text = NSAttributedString(string: "10:42", attributes: [.font: font, .foregroundColor: color])
            let t = text.size()
            let origin: CGPoint
            switch position {
            case .top: origin = CGPoint(x: (size.width - t.width) / 2, y: size.height * 0.18)
            case .bottom: origin = CGPoint(x: (size.width - t.width) / 2, y: size.height * 0.82 - t.height)
            case .left: origin = CGPoint(x: size.width * 0.12, y: (size.height - t.height) / 2)
            case .right: origin = CGPoint(x: size.width * 0.88 - t.width, y: (size.height - t.height) / 2)
            }
            text.draw(at: origin)
        }
    }

    // MARK: Template

    /// Documented watch-face server (Others/WF/WATCHFACE_SERVER_EN.md). Access can
    /// depend on the vendor; when it fails, import a template .bin from Files.
    func fetchTemplate(ui: FitCloudWatchfaceUIInfo) {
        guard let fw = FitCloudKit.allConfig()?.firmware else { say("Reloj no listo"); return }
        let newGUI = fw.isNewGUIArchitecture
        let platform = Watch.platform
        let path = newGUI ? "customgui" : "custom"
        var req = URLRequest(url: URL(string: "http://fitcloud.hetangsmart.com/public/dial/\(path)")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = "lcd=\(ui.lcd)&toolVersion=\(Self.enc(ui.toolVersion ?? ""))"
        if newGUI { body += "&platform=\(platform)" }
        req.httpBody = body.data(using: .utf8)
        say("Pidiendo plantilla (lcd \(ui.lcd), \(ui.toolVersion ?? "?"), \(path))…")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            guard let self else { return }
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.say("Servidor de plantillas no disponible: \(err?.localizedDescription ?? "respuesta no válida")")
                return
            }
            let code = (json["errorCode"] as? Int) ?? -1
            let items = json["data"] as? [[String: Any]] ?? []
            // /custom returns five date styles; prefer "White" for a clean look.
            let item = items.first { ($0["styleName"] as? String) == "White" } ?? items.first
            guard code == 0, let urlStr = item?["binUrl"] as? String, let url = URL(string: urlStr) else {
                self.say("Sin plantilla para este reloj (código \(code): \(json["errorMsg"] as? String ?? "-")). Importa un .bin desde Archivos.")
                return
            }
            let expected = (item?["binSize"] as? Int) ?? (item?["binSize"] as? NSNumber)?.intValue
            URLSession.shared.downloadTask(with: url) { tmp, response, err in
                guard let tmp else { self.say("Descarga fallida: \(err?.localizedDescription ?? "-")"); return }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    self.say("Descarga rechazada (HTTP \(http.statusCode)); no se guarda nada")
                    return
                }
                self.store(templateAt: tmp, expectedSize: expected)
            }.resume()
        }.resume()
    }

    func importTemplate(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        store(templateAt: url, expectedSize: nil)
    }

    func removeTemplate() {
        try? FileManager.default.removeItem(at: Self.templateURL)
        templateReady = false
        say("Plantilla eliminada")
    }

    /// Validates before keeping a template: it will be written into the watch,
    /// so an HTML error page or a truncated download must never be stored.
    private func store(templateAt src: URL, expectedSize: Int?) {
        guard let data = try? Data(contentsOf: src) else { say("No se pudo leer la plantilla"); return }
        if data.count < 1024 {
            say("Archivo demasiado pequeño (\(data.count) bytes); no parece una plantilla")
            return
        }
        if let head = String(data: data.prefix(64), encoding: .utf8)?.lowercased(),
           head.contains("<html") || head.contains("<!doctype") || head.hasPrefix("{") {
            say("El archivo es una página o JSON, no una plantilla binaria; descartado")
            return
        }
        if let expectedSize, expectedSize > 0, expectedSize != data.count {
            say("Tamaño inesperado (\(data.count) de \(expectedSize) bytes); descartado")
            return
        }
        do {
            try data.write(to: Self.templateURL, options: .atomic)
            onMain { self.templateReady = true }
            say("Plantilla guardada (\(data.count) bytes)")
        } catch {
            say("No se pudo guardar la plantilla: \(error.localizedDescription)")
        }
    }

    private static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    // MARK: Create + install

    /// - Parameter onFinish: called on the main thread with the final result.
    func install(bk: UIImage, ui: FitCloudWatchfaceUIInfo?, position: Position, color: UIColor,
                 onFinish: ((Bool) -> Void)? = nil) {
        guard templateReady else { say("Falta la plantilla de esfera"); onFinish?(false); return }
        guard let fw = FitCloudKit.allConfig()?.firmware else { say("Reloj no listo"); onFinish?(false); return }
        guard begin(onFinish) else { onFinish?(false); return }
        let preview = Self.preview(bk: bk, ui: ui, position: position, color: color)
        FitCloudWFKit.create(withTemplateBin: Self.templateURL.path,
                             isNextGUI: fw.isNewGUIArchitecture,
                             rewriteNextGUIWatchfaceNo: nil,
                             bkImage: bk,
                             bkCornerRadius: 0,
                             preview: preview,
                             dtPosition: position.sdk,
                             dtStyle: nil,
                             dtColor: color) { [weak self] p, tips in
            self?.onMain { self?.touch() }
            self?.say("Creando esfera \(Int(p * 100))% \(tips ?? "")")
        } logging: { _, _ in
        } completion: { [weak self] ok, binPath, _, _, err in
            guard let self else { return }
            guard ok, let binPath else {
                self.fail("No se pudo crear la esfera: \(err?.localizedDescription ?? "-")")
                return
            }
            self.say("Esfera creada; enviando al reloj…")
            self.onMain { self.push([binPath]) }
        }
    }

    // MARK: Transfer queue (main thread only)

    private func push(_ paths: [String]) {
        queue = paths
        total = paths.count
        pushNext()
    }

    private func pushNext() {
        guard busy else { return }  // cancelled meanwhile
        guard !queue.isEmpty else {
            done(total > 1 ? "\(total) archivos enviados al reloj" : "Instalado en el reloj")
            return
        }
        guard let fw = FitCloudKit.allConfig()?.firmware, Watch.shared.connected else {
            fail("El reloj no está conectado")
            return
        }
        let path = queue.removeFirst()
        progress = 0
        touch()
        if total > 1 { say("Enviando \(total - queue.count) de \(total)…") }
        if fw.withNewOTA { pushNewOTA(path) } else { pushDFU(path) }
    }

    private func itemFinished() {
        onMain {
            self.touch()
            if self.queue.isEmpty {
                self.pushNext()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.pushNext() }
            }
        }
    }

    private func pushNewOTA(_ path: String) {
        FitCloudKit.sendNewOTA(path) { [weak self] started, err in
            if !started { self?.fail("OTA no inició: \(err?.localizedDescription ?? "-")") }
        } progress: { [weak self] p in
            self?.onMain { self?.touch(); self?.progress = Double(p) }
        } completion: { [weak self] ok, _, err in
            if ok { self?.itemFinished() }
            else { self?.fail("OTA falló: \(err?.localizedDescription ?? "-")") }
        }
    }

    private func pushDFU(_ path: String) {
        FitCloudKit.enterDFUMode { [weak self] ok, peripheral, _, err in
            guard ok, let peripheral else {
                self?.fail("No entró en modo DFU: \(err?.localizedDescription ?? "-")")
                return
            }
            // Watch-face DFU is "UI DFU": always silent mode (FitCloudDFUKit README).
            FitCloudDFUKit.start(with: peripheral, firmware: path, chipVendor: .REALTEK, silentMode: true)
        }
    }

    // MARK: Status

    private func say(_ s: String) {
        onMain {
            self.message = s
            Watch.shared.note(s)
        }
    }

    private func fail(_ s: String) {
        onMain {
            guard self.busy || !self.queue.isEmpty else { self.say(s); return }
            self.finish(false, s)
        }
    }

    private func done(_ s: String) {
        onMain {
            self.progress = 1
            self.finish(true, s)
            Watch.shared.loadAll()
        }
    }

    private func finish(_ ok: Bool, _ s: String) {
        say(s)
        queue = []
        waitingForReconnect = false
        busy = false
        watchdog?.invalidate()
        watchdog = nil
        let handler = finishHandler
        finishHandler = nil
        handler?(ok)
    }
}

extension FaceStudio: FitCloudDFUDelegate {
    func onStartDFUSuccess() {
        onMain { self.touch() }
        say("Transferencia DFU iniciada")
    }
    func onStartDFUFailureWithError(_ error: Error) { fail("DFU no inició: \(error.localizedDescription)") }
    func onDFUProgress(_ progress: CGFloat, imageIndex index: Int, total: Int) {
        onMain {
            self.touch()
            self.progress = Double(progress) / 100
        }
    }
    func onAbortWithError(_ error: Error) { fail("DFU abortado: \(error.localizedDescription)") }
    func onDFUFinish(withSpeed speed: CGFloat) {
        onMain {
            self.touch()
            if self.queue.isEmpty {
                self.done(self.total > 1 ? "\(self.total) archivos enviados; el reloj reinicia su interfaz"
                                         : "Instalado; el reloj reinicia su interfaz")
            } else {
                self.say("Archivo enviado; esperando a que el reloj vuelva a conectar…")
                self.waitingForReconnect = true
            }
        }
    }
    func onDFULogMessage(_ message: String, level: FCDFUKLogLevel) {}
}
