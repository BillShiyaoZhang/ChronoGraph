// filepath: /Users/shiyaozhang/Developer/ChronoGraph/ChronoGraph/Managers/ExportedImageItemSource.swift
//  Provides a UIActivityItemSource so the share sheet can correctly treat the exported
//  content as an image (thumbnail + metadata). Also exposes a temp file URL so some
//  receivers that prefer file-based ingestion (e.g. AirDrop previews) work reliably.

import UIKit
import LinkPresentation

final class ExportedImageItemSource: NSObject, UIActivityItemSource {
    private let image: UIImage
    private let fileURL: URL?
    private let compressionQuality: CGFloat

    init(image: UIImage, compressionQuality: CGFloat = 0.85) {
        self.image = image
        self.compressionQuality = min(max(compressionQuality, 0.01), 1.0)
        // Persist as JPEG in tmp to reduce size.
        if let data = image.jpegData(compressionQuality: self.compressionQuality) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("chrono_export_\(UUID().uuidString).jpg")
            try? data.write(to: url)
            self.fileURL = url
        } else if let fallback = image.pngData() { // Fallback if JPEG encoding fails (rare)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("chrono_export_\(UUID().uuidString).png")
            try? fallback.write(to: url)
            self.fileURL = url
        } else {
            self.fileURL = nil
        }
        super.init()
    }

    // Placeholder used immediately; lightweight object.
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { UIImage() }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        if let fileURL { return fileURL }
        return image
    }

    // Provide rich link metadata (iMessage, AirDrop preview, etc.)
    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = NSLocalizedString("export.metadata.titleJPG", comment: "Exported Image (JPG)")
        metadata.imageProvider = NSItemProvider(object: image)
        if let fileURL { metadata.originalURL = fileURL }
        return metadata
    }
}
