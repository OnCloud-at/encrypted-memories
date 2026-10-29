#if os(macOS)
    import AppKit
    import CoreGraphics
    import PhotosCore
    import SwiftUI
    import UploadCore
    import XCTest

    @testable import UploadFeature

    /// Problem-list rows without a Photos source reserve the same thumbnail square as rows with one, show the same
    /// gray placeholder, and ask for no picture.
    @MainActor
    final class BackupProblemRowTests: XCTestCase {
        private static let renderedWidth = 320
        private static let renderedHeight = 80
        private static let photo = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "fixture-x")

        func testARowWithoutASourceShowsTheSamePlaceholderAsARowWhosePictureCannotLoad() async throws {
            let model = BackupProblemPreviewModel { _ in nil }
            let expected = try await Self.capture(
                Self.row(source: Self.photo, model: model)
            ).takeInk()

            for (name, source) in [
                ("no source", nil as UploadSourceIdentity?),
                ("a folder file", UploadSourceIdentity(kind: .fileURL, identifier: "fixture.jpg")),
                ("an empty identifier", UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "")),
            ] {
                let ink = try await Self.capture(Self.row(source: source, model: model)).takeInk()
                XCTAssertEqual(
                    ink, expected,
                    "a row with \(name) shows the placeholder of a row whose picture cannot load")
            }
        }

        func testARowWithoutAPreviewsModelReservesTheSquareAndShowsThePlaceholder() async throws {
            let previews = BackupProblemPreviewModel { _ in nil }
            previews.open()
            defer { previews.close() }
            let withoutModel = BackupProblemRow(item: Self.item(source: nil))
            let withSource = BackupProblemRow(item: Self.item(source: Self.photo), previews: previews)

            // A direct size guard: the row must fit the 40-point thumbnail square; its text alone is 35 tall.
            XCTAssertGreaterThanOrEqual(
                Self.fittedSize(of: withoutModel).height, 40,
                "a row without a previews model reserves the height of the thumbnail square")
            XCTAssertEqual(
                Self.fittedSize(of: withoutModel), Self.fittedSize(of: withSource),
                "a row without a previews model reserves the same thumbnail square")

            // A direct symbol guard: the leading 40 columns hold the photo symbol's ink, not only flat fill.
            let symbol = try await Self.capture(withoutModel).inkCount(columns: 0..<40)
            XCTAssertGreaterThanOrEqual(symbol, 25, "the placeholder shows the photo symbol")
            XCTAssertLessThanOrEqual(symbol, 1_000, "the placeholder square is mostly flat fill")
        }

        func testMixedRowsLineUpAndARowWithoutASourceRequestsNoPicture() async throws {
            let loads = LoadLog()
            let previews = BackupProblemPreviewModel { _ in Self.magentaBitmap() }
            previews.open()
            defer { previews.close() }
            let sourceless = BackupProblemPreviewModel(load: loads.load)
            sourceless.open()
            defer { sourceless.close() }
            let withSource = BackupProblemRow(item: Self.item(source: Self.photo), previews: previews)
            let withoutSource = BackupProblemRow(item: Self.item(source: nil), previews: sourceless)

            // Fitted sizes are synchronous, so no window is needed to compare the reserved squares.
            XCTAssertEqual(
                Self.fittedSize(of: withoutSource), Self.fittedSize(of: withSource),
                "a row without a source reserves the same thumbnail square")

            let picture = try await Self.capture(withSource)
            let placeholder = try await Self.capture(withoutSource)
            XCTAssertTrue(loads.requested.isEmpty, "a row without a source requests no picture")
            let band = try XCTUnwrap(picture.magentaColumns())
            XCTAssertEqual(band.count, 40, "the row with a source keeps its thumbnail square")
            XCTAssertEqual(
                placeholder.takeInk(fromColumn: band.upperBound), picture.takeInk(fromColumn: band.upperBound),
                "the category symbol and the text of both rows start at the same edges")
        }

        // MARK: - Building

        private static func item(source: UploadSourceIdentity?) -> BackupFailedItem {
            BackupFailedItem(
                id: "fixture", filename: "Fixture.heic", reason: "Fixture reason", isPermanent: false,
                source: source)
        }

        private static func row(source: UploadSourceIdentity?, model: BackupProblemPreviewModel) -> some View {
            BackupProblemRow(item: item(source: source), previews: model)
        }

        private static func fittedSize(of row: some View) -> CGSize {
            NSHostingView(rootView: row).fittingSize
        }

        /// Draws a row in a window long enough for its thumbnail task to settle, then caches the drawn pixels.
        private static func capture(_ view: some View) async throws -> DrawnPixels {
            let framed =
                view
                .frame(
                    width: CGFloat(Self.renderedWidth),
                    height: CGFloat(Self.renderedHeight)
                )
                .background(Color.white)
                .environment(\.colorScheme, .light)
            let host = NSHostingView(rootView: framed)
            host.frame = NSRect(x: 0, y: 0, width: Self.renderedWidth, height: Self.renderedHeight)
            let window = NSWindow(
                contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            for _ in 0..<10 {
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
            let rep = try XCTUnwrap(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Self.renderedWidth, pixelsHigh: Self.renderedHeight,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: Self.renderedWidth * 4, bitsPerPixel: 32))
            host.cacheDisplay(in: host.bounds, to: rep)
            return DrawnPixels(rep: rep)
        }

        /// The one preview square the row loads, in a color no other row content uses.
        nonisolated private static func magentaBitmap() -> CGImage? {
            let side = 8
            guard
                let context = CGContext(
                    data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.setFillColor(red: 1, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            return context.makeImage()
        }
    }

    /// Records every picture request of a preview model.
    @MainActor
    private final class LoadLog {
        private(set) var requested: [String] = []

        func load(_ uid: PhotoUID) async -> CGImage? {
            requested.append(uid.nodeID)
            return nil
        }
    }

    /// The cached pixels of one rendered row: ink for the layout, magenta for the loaded preview square.
    private struct DrawnPixels {
        private static let inkLimit = CGFloat(200) / 255

        let width: Int
        let height: Int
        private let colors: [[NSColor]]

        init(rep: NSBitmapImageRep) {
            let width = rep.pixelsWide
            let height = rep.pixelsHigh
            self.width = width
            self.height = height
            colors = (0..<height).map { y in
                (0..<width).map { x in rep.colorAt(x: x, y: y) ?? NSColor.white }
            }
        }

        /// How many pixels draw content within the given columns.
        func inkCount(columns: Range<Int>) -> Int {
            columns.reduce(0) { count, x in
                count + (0..<height).filter { isDrawn(colors[$0][x]) }.count
            }
        }

        /// Which pixels draw content, from a column on, so identical rows produce identical grids.
        func takeInk(fromColumn column: Int = 0) -> InkGrid {
            InkGrid(
                width: width - column, height: height,
                ink: (0..<height).flatMap { y in (column..<width).map { x in isDrawn(colors[y][x]) } })
        }

        /// The columns of the loaded preview square.
        func magentaColumns() -> Range<Int>? {
            let present = (0..<height).flatMap { y in (0..<width).filter { x in isPreview(colors[y][x]) } }
            guard let first = present.min(), let last = present.max() else { return nil }
            return first..<(last + 1)
        }

        private func isDrawn(_ color: NSColor) -> Bool {
            color.redComponent < Self.inkLimit
                || color.greenComponent < Self.inkLimit || color.blueComponent < Self.inkLimit
        }

        private func isPreview(_ color: NSColor) -> Bool {
            color.redComponent > 0.78 && color.greenComponent < 0.24 && color.blueComponent > 0.78
        }
    }

    /// Which pixels of a row draw content.
    private struct InkGrid: Equatable {
        let width: Int
        let height: Int
        let ink: [Bool]
    }
#endif
