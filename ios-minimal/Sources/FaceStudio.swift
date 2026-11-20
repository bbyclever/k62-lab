import Foundation
import UIKit
import CoreImage
import FitCloudKit
import FitCloudDFUKit
import FitCloudWFKit

/// Everything the user chooses about how the time looks on the watch.
/// Stored in UserDefaults (same keys as the @AppStorage controls in FaceView).
struct FaceStyle: Equatable {
    /// What is drawn behind the time so it stays legible on any photo.
    enum Backdrop: Int, CaseIterable, Identifiable {
        case none = 0, shadow = 1, smoked = 2
        var id: Int { rawValue }
        var label: String { ["Nada", "Sombra", "Cristal ahumado"][rawValue] }
    }

    var position: FaceStudio.Position = .bottom
    /// -1 = template default; 0…5 = the watch's own time/date styles (fonts), FitCloudWFKit `dtStyle`.
    /// Style 1 (0) verified on the K62: bold digits + date.
    var timeStyle: Int = 0
    var colorHex: String = "FFFFFF"
    var backdrop: Backdrop = .shadow

    var color: UIColor { UIColor(hex: colorHex) }

    static var saved: FaceStyle {
        let d = UserDefaults.standard
        var s = FaceStyle()
        if d.object(forKey: "k62.face.position") != nil {
            s.position = FaceStudio.Position(rawValue: d.integer(forKey: "k62.face.position")) ?? .bottom
        }
        if d.object(forKey: "k62.face.timeStyle") != nil { s.timeStyle = d.integer(forKey: "k62.face.timeStyle") }
        s.colorHex = d.string(forKey: "k62.face.colorHex") ?? "FFFFFF"
        if d.object(forKey: "k62.face.backdrop") != nil {
            s.backdrop = Backdrop(rawValue: d.integer(forKey: "k62.face.backdrop")) ?? .shadow
        }
        return s
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    convenience init(hex: String) {
        let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xFFFFFF
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", c(r), c(g), c(b))
    }
}

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

    // MARK: Colour backgrounds, generated at the exact screen size
    //
    // The K62 has a TFT panel: "black" glows grey-blue, so pure-black OLED
    // designs look cheap. Deep colour gradients with soft light look rich.

    private struct Glow {
        let x: CGFloat, y: CGFloat, r: CGFloat, color: UInt32, alpha: CGFloat
    }

    private struct Backgrounds {
        let top: UInt32, bottom: UInt32
        let glows: [Glow]
    }

    private static let palettes: [String: Backgrounds] = [
        "aurora": Backgrounds(top: 0x0B1A2E, bottom: 0x10324A, glows: [
            Glow(x: 0.15, y: 0.2, r: 0.75, color: 0x2BD9A8, alpha: 0.55),
            Glow(x: 0.9, y: 0.75, r: 0.85, color: 0x6A5CFF, alpha: 0.55)]),
        "oceano": Backgrounds(top: 0x041230, bottom: 0x0A3D62, glows: [
            Glow(x: 0.85, y: 0.15, r: 0.8, color: 0x1FA2FF, alpha: 0.55),
            Glow(x: 0.1, y: 0.95, r: 0.7, color: 0x12D8FA, alpha: 0.35)]),
        "atardecer": Backgrounds(top: 0x2B1055, bottom: 0x7A1F5C, glows: [
            Glow(x: 0.85, y: 0.9, r: 0.9, color: 0xFF8C42, alpha: 0.65),
            Glow(x: 0.1, y: 0.15, r: 0.7, color: 0xFF3CAC, alpha: 0.45)]),
        "bosque": Backgrounds(top: 0x0B2B26, bottom: 0x163832, glows: [
            Glow(x: 0.2, y: 0.25, r: 0.7, color: 0x8EB69B, alpha: 0.35),
            Glow(x: 0.85, y: 0.85, r: 0.8, color: 0x2F7A5F, alpha: 0.6)]),
        "grafito": Backgrounds(top: 0x1C1C1E, bottom: 0x2C2C30, glows: [
            Glow(x: 0.25, y: 0.2, r: 0.8, color: 0x5A5A62, alpha: 0.45),
            Glow(x: 0.85, y: 0.9, r: 0.7, color: 0x3A3A40, alpha: 0.5)]),
        "medianoche": Backgrounds(top: 0x05051A, bottom: 0x0D0D2B, glows: [
            Glow(x: 0.8, y: 0.25, r: 0.8, color: 0x3B2F8F, alpha: 0.55),
            Glow(x: 0.15, y: 0.85, r: 0.6, color: 0x1E3A8A, alpha: 0.45)]),
    ]

    static let designs = ["aurora", "oceano", "atardecer", "bosque", "grafito", "medianoche"]
    static let designNames = ["aurora": "Aurora", "oceano": "Océano", "atardecer": "Atardecer",
                              "bosque": "Bosque", "grafito": "Grafito", "medianoche": "Medianoche"]
    private static var generatedCache: [String: UIImage] = [:]

    static func background(_ design: String, for ui: FitCloudWatchfaceUIInfo?) -> UIImage? {
        let size = screenSize(ui)
        let id = palettes[design] == nil ? "aurora" : design
        let key = "\(id)-\(Int(size.width))x\(Int(size.height))"
        if let hit = generatedCache[key] { return hit }
        guard let p = palettes[id] else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let base = [UIColor(rgb: p.top).cgColor, UIColor(rgb: p.bottom).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: space, colors: base, locations: [0, 1]) {
                cg.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            for glow in p.glows {
                let c = UIColor(rgb: glow.color)
                let colors = [c.withAlphaComponent(glow.alpha).cgColor, c.withAlphaComponent(0).cgColor] as CFArray
                guard let g = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { continue }
                let center = CGPoint(x: size.width * glow.x, y: size.height * glow.y)
                cg.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center,
                                      endRadius: max(size.width, size.height) * glow.r, options: [])
            }
        }
        generatedCache[key] = img
        return img
    }

    // MARK: Composition (what is really written to the watch)

    private static let ciContext = CIContext()
    private static var composeCache: [String: UIImage] = [:]

    static func screenSize(_ ui: FitCloudWatchfaceUIInfo?) -> CGSize {
        let s = ui?.screenResolution() ?? .zero
        return s.width > 0 && s.height > 0 ? s : CGSize(width: 240, height: 284)
    }

    /// Area where the firmware draws time + date for each position (approximate,
    /// tuned for the K62 240×284 template; scales with the screen).
    static func panelRect(_ size: CGSize, _ position: Position) -> CGRect {
        let w = size.width, h = size.height
        switch position {
        case .top: return CGRect(x: w * 0.07, y: h * 0.07, width: w * 0.86, height: h * 0.36)
        case .bottom: return CGRect(x: w * 0.07, y: h * 0.57, width: w * 0.86, height: h * 0.36)
        case .left: return CGRect(x: w * 0.05, y: h * 0.28, width: w * 0.52, height: h * 0.44)
        case .right: return CGRect(x: w * 0.43, y: h * 0.28, width: w * 0.52, height: h * 0.44)
        }
    }

    /// Background at the exact screen size: image (aspect fill) plus what goes
    /// behind the time. Designed for the K62's TFT: no thin frames, no milky
    /// white boxes — a soft dark shadow or a smoked (dark) glass panel.
    static func compose(_ bk: UIImage, ui: FitCloudWatchfaceUIInfo?, style: FaceStyle) -> UIImage {
        let size = screenSize(ui)
        let key = "\(ObjectIdentifier(bk).hashValue)-\(Int(size.width))x\(Int(size.height))-\(style.position.rawValue)-\(style.backdrop.rawValue)"
        if let hit = composeCache[key] { return hit }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let rect = CGRect(origin: .zero, size: size)
        let base = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(rect)
            bk.draw(in: aspectFill(bk.size, in: rect))
        }
        let space = CGColorSpaceCreateDeviceRGB()
        let result: UIImage
        switch style.backdrop {
        case .none:
            result = base
        case .shadow:
            // Full-width dark fade towards the edge where the time sits.
            let (start, end) = shadowAxis(size, style.position)
            let colors = [UIColor.black.withAlphaComponent(0).cgColor, UIColor.black.withAlphaComponent(0.72).cgColor] as CFArray
            result = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                base.draw(in: rect)
                if let g = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
                    ctx.cgContext.drawLinearGradient(g, start: start, end: end,
                                                     options: [.drawsAfterEndLocation])
                }
            }
        case .smoked:
            let blurred = blur(base, radius: size.width * 0.08)
            let panel = panelRect(size, style.position)
            let path = UIBezierPath(roundedRect: panel, cornerRadius: min(panel.width, panel.height) * 0.3)
            result = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                base.draw(in: rect)
                ctx.cgContext.saveGState()
                path.addClip()
                blurred.draw(in: rect)
                UIColor.black.withAlphaComponent(0.38).setFill()
                path.fill()
                let colors = [UIColor.white.withAlphaComponent(0.10).cgColor, UIColor.white.withAlphaComponent(0).cgColor] as CFArray
                if let g = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
                    ctx.cgContext.drawLinearGradient(g, start: CGPoint(x: panel.midX, y: panel.minY),
                                                     end: CGPoint(x: panel.midX, y: panel.minY + panel.height * 0.45), options: [])
                }
                ctx.cgContext.restoreGState()
            }
        }
        if composeCache.count > 40 { composeCache.removeAll() }
        composeCache[key] = result
        return result
    }

    /// Gradient axis for the shadow: from transparent (inside) to dark (edge with the time).
    private static func shadowAxis(_ size: CGSize, _ position: Position) -> (CGPoint, CGPoint) {
        let w = size.width, h = size.height
        switch position {
        case .bottom: return (CGPoint(x: 0, y: h * 0.42), CGPoint(x: 0, y: h * 0.95))
        case .top: return (CGPoint(x: 0, y: h * 0.58), CGPoint(x: 0, y: h * 0.05))
        case .left: return (CGPoint(x: w * 0.7, y: 0), CGPoint(x: w * 0.05, y: 0))
        case .right: return (CGPoint(x: w * 0.3, y: 0), CGPoint(x: w * 0.95, y: 0))
        }
    }

    private static func aspectFill(_ img: CGSize, in rect: CGRect) -> CGRect {
        guard img.width > 0, img.height > 0 else { return rect }
        let k = max(rect.width / img.width, rect.height / img.height)
        let w = img.width * k, h = img.height * k
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    private static func blur(_ img: UIImage, radius: CGFloat) -> UIImage {
        guard let ci = CIImage(image: img), let f = CIFilter(name: "CIGaussianBlur") else { return img }
        f.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
        f.setValue(radius, forKey: kCIInputRadiusKey)
        guard let out = f.outputImage?.cropped(to: ci.extent),
              let cg = ciContext.createCGImage(out, from: ci.extent) else { return img }
        return UIImage(cgImage: cg)
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

    /// Installs a face using the saved FaceStyle (position, watch font style,
    /// colour, glass panel). `compose: false` sends `bk` as-is (already designed).
    /// - Parameter onFinish: called on the main thread with the final result.
    func install(bk: UIImage, ui: FitCloudWatchfaceUIInfo?, style: FaceStyle = .saved, compose: Bool = true,
                 onFinish: ((Bool) -> Void)? = nil) {
        guard templateReady else { say("Falta la plantilla de esfera"); onFinish?(false); return }
        guard let fw = FitCloudKit.allConfig()?.firmware else { say("Reloj no listo"); onFinish?(false); return }
        guard begin(onFinish) else { onFinish?(false); return }
        let background = compose ? Self.compose(bk, ui: ui, style: style) : bk
        let preview = Self.preview(bk: background, ui: ui, position: style.position, color: style.color)
        let dtStyle: NSNumber? = (0...5).contains(style.timeStyle) ? NSNumber(value: style.timeStyle) : nil
        say("Creando esfera (hora \(dtStyle.map { "estilo \($0.intValue + 1)" } ?? "por defecto"))…")
        FitCloudWFKit.create(withTemplateBin: Self.templateURL.path,
                             isNextGUI: fw.isNewGUIArchitecture,
                             rewriteNextGUIWatchfaceNo: nil,
                             bkImage: background,
                             bkCornerRadius: 0,
                             preview: preview,
                             dtPosition: style.position.sdk,
                             dtStyle: dtStyle,
                             dtColor: style.color) { [weak self] p, tips in
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
