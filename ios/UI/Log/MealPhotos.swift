import Foundation
import UIKit

/// Meal photos (tracker #42, 2026-10-11): kept on this iPhone only, never uploaded. Not in any drop, not named in the
/// food event (the contract's `photo` field means "in the day folder", which this is not), excluded from the iCloud
/// backup. One small JPEG per food event, named by the event's id: at most 1024 px on the long side, quality 0.6 —
/// about 100–250 KB each, so a photo a day for a year is roughly 50–90 MB. Removing a food entry keeps its photo
/// (removing is soft; nothing is deleted).
enum MealPhotos {
    static let maxSide: CGFloat = 1024
    static let quality: CGFloat = 0.6

    static func folder() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        var dir = base.appendingPathComponent("MealPhotos", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var v = URLResourceValues()
            v.isExcludedFromBackup = true
            try dir.setResourceValues(v)
        }
        return dir
    }

    static func url(for eventId: UUID) throws -> URL {
        try folder().appendingPathComponent(eventId.uuidString.lowercased() + ".jpg")
    }

    /// The image scaled down to `maxSide` and JPEG-encoded; nil when it cannot be encoded.
    static func jpeg(_ image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxSide ? maxSide / longest : 1
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return small.jpegData(compressionQuality: quality)
    }

    /// Writes the photo for `eventId` (a new file; an existing one is never overwritten). Returns its size in bytes.
    @discardableResult
    static func save(_ image: UIImage, eventId: UUID) throws -> Int {
        guard let data = jpeg(image) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: try url(for: eventId), options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
        return data.count
    }

    static func image(for eventId: UUID) -> UIImage? {
        guard let u = try? url(for: eventId), let data = try? Data(contentsOf: u) else { return nil }
        return UIImage(data: data)
    }
}

#if canImport(PhotosUI)
import PhotosUI
import SwiftUI

/// The system photo picker (PHPickerViewController: no photo-library permission needed; the app sees only the one
/// photo picked). Calls `done` with the image, or nil when cancelled.
struct MealPhotoPicker: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let done: (UIImage?) -> Void
        init(done: @escaping (UIImage?) -> Void) { self.done = done }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else {
                return done(nil)
            }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                let image = object as? UIImage
                DispatchQueue.main.async { self.done(image) }
            }
        }
    }
}
#endif
