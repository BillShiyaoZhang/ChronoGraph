//
//  ImageExportManager.swift
//  ChronoGraph
//
//  Created by Shiyao Zhang on 05/09/2025.
//

import SwiftUI
import UIKit

@MainActor
class ImageExportManager: ObservableObject {
    @Published var generatedImage: UIImage?
    @Published var isGeneratingImage = false
    @Published var showingShareSheet = false

    /// Bound both the longest side and the bitmap allocation (about 64 MB of RGBA pixels).
    /// Long calendars need a scale below 1; clamping it to 1 defeats the size limit.
    static func renderScale(for size: CGSize, displayScale: CGFloat) -> CGFloat? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let preferredScale = displayScale.isFinite && displayScale > 0 ? min(displayScale, 2) : 1
        let dimensionScale = 16_384 / max(size.width, size.height)
        // Divide square roots separately to avoid overflow for invalid/extreme layouts.
        let areaScale = sqrt(16_000_000) / sqrt(size.width) / sqrt(size.height)
        let scale = min(preferredScale, dimensionScale, areaScale)
        guard scale.isFinite, scale > 0, min(size.width, size.height) * scale >= 1 else { return nil }
        return scale
    }
    
    // Export contract:
    // - Input: Any SwiftUI view representing the export content
    // - Behavior: Forces a deterministic layout width, intrinsic vertical height, light mode, and solid background
    // - Output: High-resolution UIImage; avoids blank output on some layouts
    func generateImage(from view: AnyView, targetWidth: CGFloat? = nil, colorScheme: ColorScheme = .light) async {
        isGeneratingImage = true
        defer { isGeneratingImage = false }
        generatedImage = nil
        
        let targetWidthPoints: CGFloat = targetWidth ?? 1000
        guard targetWidthPoints.isFinite, targetWidthPoints > 0 else { return }
        
        // Ensure stable layout and non-transparent background to avoid blank exports
        let exportView = AnyView(
            view
                .frame(width: targetWidthPoints)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color(.systemBackground))
                .environment(\.colorScheme, colorScheme)
        )
        
        // Pre-measure the view height using a lightweight hosting controller
        // so we can cap the pixel scale for very tall content (e.g., weekly view)
        let measuringHost = UIHostingController(rootView: exportView)
        measuringHost.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        measuringHost.view.backgroundColor = .systemBackground
        measuringHost.view.frame = CGRect(x: 0, y: 0, width: targetWidthPoints, height: 10)
        let targetSize = measuringHost.sizeThatFits(in: CGSize(width: targetWidthPoints, height: .greatestFiniteMagnitude))
        
        // Resolve display scale without using deprecated UIScreen.main (iOS 26+ deprecates it)
        // Prefer a screen from the current context; fall back to traitCollection then legacy main.
        func resolvedDisplayScale(from view: UIView) -> CGFloat {
            if #available(iOS 17.0, *) { // (26.0 deprecates .main; keep compatibility path)
                if let screen = view.window?.windowScene?.screen { return screen.scale }
                return view.traitCollection.displayScale
            } else {
                return UIScreen.main.scale
            }
        }
        let baseScale = resolvedDisplayScale(from: measuringHost.view)
        
        guard let safeScale = Self.renderScale(for: targetSize, displayScale: baseScale) else { return }
        
        // Preferred path: ImageRenderer (iOS 16+)
        if #available(iOS 16.0, *) {
            let renderer = ImageRenderer(content: exportView)
            renderer.proposedSize = ProposedViewSize(width: targetWidthPoints, height: targetSize.height)
            renderer.scale = safeScale
            renderer.isOpaque = true
            
            if let image = renderer.uiImage {
                self.generatedImage = image
                return
            }
            // Fall through to UIKit snapshot if uiImage is unexpectedly nil
        }
        
        // Fallback: UIKit snapshot via UIHostingController (works broadly)
        let hosting = UIHostingController(rootView: exportView)
        hosting.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        hosting.view.backgroundColor = .systemBackground
        hosting.view.frame = CGRect(x: 0, y: 0, width: targetWidthPoints, height: 10)
        let fittedSize = targetSize
        hosting.view.bounds = CGRect(origin: .zero, size: fittedSize)
        hosting.view.layoutIfNeeded()
        
        let format = UIGraphicsImageRendererFormat()
        format.scale = safeScale
        format.opaque = true
        
        let renderer = UIGraphicsImageRenderer(size: fittedSize, format: format)
        let image = renderer.image { _ in
            hosting.view.drawHierarchy(in: hosting.view.bounds, afterScreenUpdates: true)
        }
        self.generatedImage = image
    }
    
    func shareImage() {
        guard generatedImage != nil else { return }
        showingShareSheet = true
    }
    
    func copyToClipboard() {
        guard let image = generatedImage else { return }
        UIPasteboard.general.image = image
    }
    
    func saveToPhotos() {
        guard let image = generatedImage else { return }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
    }
}
