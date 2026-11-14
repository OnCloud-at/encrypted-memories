#if os(macOS)
    import AppKit
    import PhotosCore
    import SwiftUI
    import XCTest
    import Vision

    @testable import AlbumsFeature

    /// Checks the shared album form and destination picker through their native Mac presentation.
    final class AlbumToolbarRenderingTests: XCTestCase {
        @MainActor func testAlbumSheetKeepsItsTextActionsOnMac() async throws {
            _ = NSApplication.shared
            try requireVisionOCR()
            let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
            let coordinator = AlbumActionCoordinator(repository: repository(backend))
            let host = NSHostingController(
                rootView: Color.clear.frame(width: 480, height: 320)
                    .sheet(isPresented: .constant(true)) { AlbumCreationSheet(coordinator: coordinator) })
            let window = NSWindow(contentViewController: host)
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            for _ in 0..<100 where window.attachedSheet == nil {
                try await Task.sleep(for: .milliseconds(50))
            }
            let sheet = try XCTUnwrap(window.attachedSheet, "Album Mac: attachedSheet unavailable")
            defer { sheet.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(500))
            let contentView = try XCTUnwrap(sheet.contentView, "Album Mac: sheet contentView unavailable")
            let view = try XCTUnwrap(contentView.superview, "Album Mac: contentView superview unavailable")
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                sheet.appearance = NSAppearance(named: appearance)
                try await Task.sleep(for: .milliseconds(300))
                let bitmap = try snapshot(of: view)
                let image = try XCTUnwrap(bitmap.cgImage, "Album Mac: bitmap cgImage unavailable")
                let observations: [VNRecognizedTextObservation]
                do {
                    observations = try recognizedText(in: image)
                } catch {
                    XCTFail("Album Mac: Vision.perform failed: \(error)")
                    throw error
                }
                let visibleText = observations.compactMap { $0.topCandidates(1).first?.string }
                print("[Album Mac] visible text=\(visibleText)")
                XCTAssertTrue(visibleText.contains(L10n.string("action.cancel")))
                XCTAssertTrue(visibleText.contains(L10n.string("albums.create_action")))
                let data = try pngData(from: bitmap)
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                attachment.name = "Album sheet \(appearance.rawValue)"
                attachment.lifetime = .keepAlways
                add(attachment)
                try saveScreenshotIfRequested(bitmap, named: "album-\(appearance.rawValue).png")
            }
        }

        @MainActor func testEmptyDestinationUsesTheSurroundingTextSize() async throws {
            _ = NSApplication.shared
            try requireVisionOCR()
            let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
            let coordinator = AlbumActionCoordinator(repository: repository(backend))
            await coordinator.refresh()
            let title = L10n.string("albums.none_available")
            let font = Font.system(size: 24)
            let reference = NSHostingView(rootView: Text(title).font(font))
            let host = NSHostingController(
                rootView: AlbumDestinationPicker(coordinator: coordinator, photoUIDs: [], onCompleted: { _ in })
                    .font(font))
            let window = NSWindow(contentViewController: host)
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(500))
            let view = try XCTUnwrap(window.contentView)
            let bitmap = try snapshot(of: view)
            let image = try XCTUnwrap(bitmap.cgImage)
            let observations = try recognizedText(in: image)
            let emptyText = try XCTUnwrap(
                observations.first { $0.topCandidates(1).first?.string == title },
                "The real destination picker must draw its existing empty text")
            let textWidth = emptyText.boundingBox.width * view.bounds.width
            let referenceWidth = reference.fittingSize.width
            XCTAssertGreaterThan(referenceWidth, 100, "The reference must measure the actual text")
            try saveScreenshotIfRequested(bitmap, named: "album-empty-row.png")
            // OCR excludes the glyph bearings; allow that small difference from the native text's width.
            XCTAssertGreaterThan(textWidth, referenceWidth * 0.9)
        }

        @MainActor private func requireVisionOCR() throws {
            let renderer = ImageRenderer(
                content: Text("Cancel Create")
                    .font(.system(size: 32))
                    .foregroundStyle(.black)
                    .padding(20)
                    .background(.white))
            renderer.scale = 2
            guard let image = renderer.cgImage else { throw XCTSkip("Vision OCR unavailable on this runner") }
            let text: String
            do {
                text = try recognizedText(in: image).compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ")
            } catch {
                throw XCTSkip("Vision OCR unavailable on this runner")
            }
            guard !text.isEmpty else { throw XCTSkip("Vision OCR unavailable on this runner") }
        }

        @MainActor private func snapshot(of view: NSView) throws -> NSBitmapImageRep {
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(
                view.bitmapImageRepForCachingDisplay(in: view.bounds), "Album Mac: bitmapRep unavailable")
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return bitmap
        }

        @MainActor private func recognizedText(in image: CGImage) throws -> [VNRecognizedTextObservation] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["de-DE", "en-US"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            return request.results ?? []
        }

        @MainActor private func pngData(from bitmap: NSBitmapImageRep) throws -> Data {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }

        @MainActor private func saveScreenshotIfRequested(_ bitmap: NSBitmapImageRep, named name: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["ALBUM_TOOLBAR_SCREENSHOT_DIR"] else { return }
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try pngData(from: bitmap).write(to: url.appendingPathComponent(name))
        }
    }
#endif
