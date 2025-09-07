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
    
    // Export contract:
    // - Input: Any SwiftUI view representing the export content
    // - Behavior: Forces a deterministic layout width, intrinsic vertical height, light mode, and solid background
    // - Output: High-resolution UIImage; avoids blank output on some layouts
    func generateImage(from view: AnyView, targetWidth: CGFloat? = nil, colorScheme: ColorScheme = .light) async {
        isGeneratingImage = true
        defer { isGeneratingImage = false }
        
        let targetWidthPoints: CGFloat = targetWidth ?? 1000
        
        // Ensure stable layout and non-transparent background to avoid blank exports
        let exportView = AnyView(
            view
                .environment(\.colorScheme, colorScheme)
                .frame(width: targetWidthPoints)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color(.systemBackground))
        )
        
        // Pre-measure the view height using a lightweight hosting controller
        // so we can cap the pixel scale for very tall content (e.g., weekly view)
        let measuringHost = UIHostingController(rootView: exportView)
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
        
        // Cap the output pixel size to avoid exceeding CoreGraphics/renderer limits
        // Conservative max pixel dimension (height or width): 16384
        // Prefer up to 2x to balance quality and size/performance
        let preferredMaxScale: CGFloat = 2
        let requestedScale = min(baseScale, preferredMaxScale)
        let maxPixelDimension: CGFloat = 16384
        let maxDimensionPoints = max(targetSize.width, targetSize.height)
        let scaleCap = maxDimensionPoints > 0 ? min(requestedScale, maxPixelDimension / maxDimensionPoints) : requestedScale
        let safeScale = max(1, scaleCap)
        
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
