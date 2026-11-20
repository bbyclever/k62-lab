import Foundation
import UIKit
import SwiftUI
import FitCloudKit

/// Photos chosen by the user. They drive:
///  * the app's living background (auto-advancing every few seconds),
///  * the watch: native photo album push when the firmware allows it, or a
///    rotating DIY watch face whose background changes every N hours.
final class PhotoCarousel: ObservableObject {
    static let shared = PhotoCarousel()

    enum Mode: String, CaseIterable, Identifiable {
        case off, album, rotate
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return "Solo en la app"
            case .album: return "Álbum del reloj"
            case .rotate: return "Esfera rotativa"
            }
        }
    }

    @Published private(set) var photos: [URL] = []
    @Published private(set) var displayIndex = 0
    @Published var mode: Mode {
        didSet {
            defaults.set(mode.rawValue, forKey: "k62.carousel.mode")
            // Only one feature may own the watch face at a time.
            if mode == .rotate && PetEngine.shared.autoFace { PetEngine.shared.autoFace = false }
        }
    }
    @Published var intervalHours: Int { didSet { defaults.set(intervalHours, forKey: "k62.carousel.hours") } }
    @Published private(set) var watchIndex: Int
    @Published private(set) var lastRotation: Date?

    static let maxPhotos = 24

    private let defaults = UserDefaults.standard
    private var cache: [URL: UIImage] = [:]
    private var backdrops: [URL: UIImage] = [:]
    private var timer: Timer?
    private var rotating = false

    static let folder: URL = {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("carousel", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private init() {
        let d = UserDefaults.standard
        mode = Mode(rawValue: d.string(forKey: "k62.carousel.mode") ?? "") ?? .off
        let h = d.integer(forKey: "k62.carousel.hours")
        intervalHours = h == 0 ? 6 : h
        watchIndex = d.integer(forKey: "k62.carousel.watchIndex")
        lastRotation = d.object(forKey: "k62.carousel.last") as? Date
        reload()
        startTimer()
    }

    // MARK: Library

    private func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        photos = files.filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if displayIndex >= photos.count { displayIndex = 0 }
    }

    /// Adds photos (downscaled, EXIF orientation applied). Returns how many were skipped by the limit.
    @discardableResult
    func add(_ images: [UIImage]) -> Int {
        let room = max(0, Self.maxPhotos - photos.count)
        for (i, img) in images.prefix(room).enumerated() {
            let name = String(format: "%.0f-%02d.jpg", Date().timeIntervalSince1970 * 1000, i)
            let small = Self.downscale(img, maxSide: 1200)
            try? small.jpegData(compressionQuality: 0.88)?.write(to: Self.folder.appendingPathComponent(name))
        }
        reload()
        return max(0, images.count - room)
    }

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        cache[url] = nil
        backdrops[url] = nil
        reload()
    }

    func image(_ url: URL) -> UIImage? {
        if let img = cache[url] { return img }
        guard let img = UIImage(contentsOfFile: url.path) else { return nil }
        cache[url] = img
        return img
    }

    var displayImage: UIImage? {
        guard !photos.isEmpty else { return nil }
        return image(photos[displayIndex % photos.count])
    }

    /// Small version for the blurred app background (blurring a full photo every
    /// frame is expensive; at this size the blur looks identical).
    var displayBackdrop: UIImage? {
        guard !photos.isEmpty else { return nil }
        let url = photos[displayIndex % photos.count]
        if let b = backdrops[url] { return b }
        guard let full = image(url) else { return nil }
        let b = Self.downscale(full, maxSide: 160)
        backdrops[url] = b
        return b
    }

    var nextWatchImage: UIImage? {
        guard !photos.isEmpty else { return nil }
        return image(photos[watchIndex % photos.count])
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            guard let self, self.photos.count > 1 else { return }
            withAnimation(.easeInOut(duration: 1.2)) {
                self.displayIndex = (self.displayIndex + 1) % self.photos.count
            }
        }
    }

    // MARK: Watch

    /// Pushes every photo to the watch's native photo album.
    func sendAlbum() {
        let imgs = photos.compactMap { image($0) }
        FaceStudio.shared.sendAlbum(imgs)
    }

    /// Installs the next photo as the watch-face background when the interval
    /// elapsed (or immediately with force). Called on app foreground and every
    /// time the watch reconnects, so it also runs while the app is in background.
    func rotateIfDue(force: Bool = false) {
        guard mode == .rotate, !photos.isEmpty, !rotating, Watch.shared.ready, !FaceStudio.shared.busy,
              FaceStudio.shared.templateReady else { return }
        if !force, let last = lastRotation, Date().timeIntervalSince(last) < Double(intervalHours) * 3600 { return }
        guard let img = nextWatchImage else { return }
        let pos = FaceStudio.Position(rawValue: defaults.integer(forKey: "k62.face.position")) ?? .top
        let amber = defaults.bool(forKey: "k62.face.amber")
        rotating = true
        FaceStudio.shared.install(bk: img, ui: Watch.shared.faceUI, position: pos,
                                  color: amber ? UIColor(red: 1, green: 0.84, blue: 0.63, alpha: 1) : .white) { [weak self] ok in
            guard let self else { return }
            self.rotating = false
            // Only advance when the watch really got the new face; on failure the
            // same photo is retried on the next opportunity.
            guard ok else { return }
            self.watchIndex = (self.watchIndex + 1) % max(self.photos.count, 1)
            self.lastRotation = Date()
            self.defaults.set(self.watchIndex, forKey: "k62.carousel.watchIndex")
            self.defaults.set(self.lastRotation, forKey: "k62.carousel.last")
        }
    }

    var nextRotationText: String {
        guard mode == .rotate else { return "" }
        guard let last = lastRotation else { return "Siguiente cambio: al conectar el reloj" }
        let next = last.addingTimeInterval(Double(intervalHours) * 3600)
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return next < Date() ? "Siguiente cambio: al conectar el reloj" : "Siguiente cambio: \(f.string(from: next))"
    }

    static func downscale(_ img: UIImage, maxSide: CGFloat) -> UIImage {
        let s = max(img.size.width, img.size.height)
        guard s > maxSide else { return img }
        let k = maxSide / s
        let size = CGSize(width: (img.size.width * k).rounded(), height: (img.size.height * k).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1  // real pixels, not points × screen scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))  // also bakes EXIF orientation
        }
    }
}
