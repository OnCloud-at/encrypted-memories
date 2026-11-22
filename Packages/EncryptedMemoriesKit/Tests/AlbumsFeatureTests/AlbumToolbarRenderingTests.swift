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
            let backend = FakeAlbumBackend(capabilities: .sdkCatalogAndWrites)
            let coordinator = AlbumActionCoordinator(repository: repository(backend))
            let texts = try await visibleTexts(
                ofSheet: AlbumCreationSheet(coordinator: coordinator), named: "Album sheet", file: "album")
            for visibleText in texts {
                XCTAssertTrue(visibleText.contains(L10n.string("action.cancel")))
                XCTAssertTrue(visibleText.contains(L10n.string("albums.create_action")))
            }
        }

        /// The Mac sheet shows the picker's navigation title and selection count above its content.
        @MainActor func testAddPhotosSheetShowsItsTitleCountAndActionsOnMac() async throws {
            let backend = FakeAlbumBackend(capabilities: .sdkCatalogAndWrites)
            let model = AlbumPhotoPickerModel(
                albumID: "album", coordinator: AlbumActionCoordinator(repository: repository(backend)))
            let photos = ["a", "b", "c"].map {
                PhotoItem(
                    uid: PhotoUID(volumeID: "volume", nodeID: $0), captureTime: .distantPast, mediaType: "image/jpeg")
            }
            await model.update(library: .loaded(photos, authority: .authoritative), albumNodeIDs: [])
            model.replaceSelection(with: Set(photos.prefix(2).map(\.uid)))
            let sheet = AlbumPhotoPickerSheet(
                model: model, library: nil, albumItems: nil, albumRevision: 0, onAlbumChanged: {},
                grid: { _ in Color.gray })
            let texts = try await visibleTexts(ofSheet: sheet, named: "Add Photos sheet", file: "add-photos")
            for visibleText in texts {
                XCTAssertTrue(visibleText.contains(L10n.string("albums.add_photos_title")), "\(visibleText)")
                XCTAssertTrue(visibleText.contains(L10n.selectionCenterText(selectedCount: 2)), "\(visibleText)")
                XCTAssertTrue(visibleText.contains(L10n.string("action.cancel")), "\(visibleText)")
                XCTAssertTrue(visibleText.contains(L10n.string("albums.add_photos_confirm")), "\(visibleText)")
            }
        }

        @MainActor func testEmptyDestinationUsesTheSurroundingTextSize() async throws {
            _ = NSApplication.shared
            try requireVisionOCR()
            let backend = FakeAlbumBackend(capabilities: .sdkCatalogAndWrites)
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

        /// Presents `content` as a sheet, renders it in light and dark, and returns the text that Vision reads in each.
        @MainActor private func visibleTexts(
            ofSheet content: some View, named name: String, file: String
        ) async throws -> [[String]] {
            _ = NSApplication.shared
            try requireVisionOCR()
            let host = NSHostingController(
                rootView: Color.clear.frame(width: 480, height: 320)
                    .sheet(isPresented: .constant(true)) { content })
            let window = NSWindow(contentViewController: host)
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            for _ in 0..<100 where window.attachedSheet == nil {
                try await Task.sleep(for: .milliseconds(50))
            }
            let sheet = try XCTUnwrap(window.attachedSheet, "\(name): attachedSheet unavailable")
            defer { sheet.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(500))
            let contentView = try XCTUnwrap(sheet.contentView, "\(name): sheet contentView unavailable")
            let view = try XCTUnwrap(contentView.superview, "\(name): contentView superview unavailable")
            var texts: [[String]] = []
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                sheet.appearance = NSAppearance(named: appearance)
                try await Task.sleep(for: .milliseconds(300))
                let bitmap = try snapshot(of: view)
                let image = try XCTUnwrap(bitmap.cgImage, "\(name): bitmap cgImage unavailable")
                let observations: [VNRecognizedTextObservation]
                do {
                    observations = try recognizedText(in: image)
                } catch {
                    XCTFail("\(name): Vision.perform failed: \(error)")
                    throw error
                }
                let visibleText = observations.compactMap { $0.topCandidates(1).first?.string }
                print("[\(name)] visible text=\(visibleText)")
                texts.append(visibleText)
                let attachment = XCTAttachment(data: try pngData(from: bitmap), uniformTypeIdentifier: "public.png")
                attachment.name = "\(name) \(appearance.rawValue)"
                attachment.lifetime = .keepAlways
                add(attachment)
                try saveScreenshotIfRequested(bitmap, named: "\(file)-\(appearance.rawValue).png")
            }
            return texts
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
