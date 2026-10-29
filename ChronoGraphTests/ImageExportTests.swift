import SwiftUI
import Testing
import UIKit
@testable import ChronoGraph

@MainActor
struct ImageExportTests {
    @Test func normalExportRetainsDisplayQuality() {
        #expect(ImageExportManager.renderScale(for: CGSize(width: 390, height: 1200), displayScale: 3) == 2)
    }

    @Test func longExportFitsWithinMaximumDimension() throws {
        let size = CGSize(width: 390, height: 50_000)
        let scale = try #require(ImageExportManager.renderScale(for: size, displayScale: 3))
        #expect(scale < 1)
        #expect(size.height * scale <= 16_384)
        #expect(size.width * scale >= 1)
    }

    @Test func wideExportAlsoRespectsBitmapMemoryBudget() throws {
        let size = CGSize(width: 10_000, height: 10_000)
        let scale = try #require(ImageExportManager.renderScale(for: size, displayScale: 2))
        #expect(size.width * size.height * scale * scale <= 16_000_001)
        #expect(scale < 1)
    }

    @Test func invalidAndUnrenderableDimensionsFailSafely() {
        for size in [CGSize.zero, CGSize(width: -1, height: 10),
                     CGSize(width: CGFloat.infinity, height: 10), CGSize(width: 10, height: CGFloat.nan),
                     CGSize(width: 1, height: 1_000_000)] {
            #expect(ImageExportManager.renderScale(for: size, displayScale: 2) == nil)
        }
        #expect(ImageExportManager.renderScale(for: CGSize(width: 100, height: 100), displayScale: 0) == 1)
    }

    @Test func longSwiftUIViewProducesBoundedImage() async throws {
        let manager = ImageExportManager()
        await manager.generateImage(from: AnyView(Color.blue.frame(height: 20_000)), targetWidth: 100)
        let image = try #require(manager.generatedImage)
        let bitmap = try #require(image.cgImage)
        #expect(bitmap.width > 0)
        #expect(bitmap.height <= 16_384)
        #expect(!manager.isGeneratingImage)
    }

    @Test func failedExportClearsPreviousImage() async {
        let manager = ImageExportManager()
        manager.generatedImage = UIImage()
        await manager.generateImage(from: AnyView(Text("Calendar")), targetWidth: .nan)
        #expect(manager.generatedImage == nil)
        #expect(!manager.isGeneratingImage)
    }
}
