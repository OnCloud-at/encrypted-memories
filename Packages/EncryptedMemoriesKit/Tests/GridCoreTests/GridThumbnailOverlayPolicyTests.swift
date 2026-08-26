import CoreGraphics
import GridCore
import Testing

@Suite struct GridThumbnailOverlayPolicyTests {
    @Test func durationAndRAWAnchorInsideDisplayedImageRect() throws {
        let displayed = CGRect(x: 20, y: 40, width: 100, height: 80)
        let layouts = GridThumbnailOverlayPolicy.layouts(
            for: GridThumbnailOverlay(durationText: "10:45", showsRAW: true),
            in: displayed
        )

        let duration = try #require(layouts.first { $0.kind == .duration })
        let raw = try #require(layouts.first { $0.kind == .raw })
        #expect(duration.backgroundRect.maxX == displayed.maxX)
        #expect(duration.backgroundRect.maxY == displayed.maxY)
        #expect(duration.backgroundRect.midX > displayed.midX)
        #expect(duration.backgroundRect.midY > displayed.midY)
        #expect(raw.backgroundRect.minX > displayed.minX)
        #expect(raw.backgroundRect.minY > displayed.minY)
        #expect(raw.backgroundRect.midY < displayed.midY)
        #expect(displayed.contains(duration.backgroundRect))
        #expect(displayed.contains(raw.backgroundRect))
        #expect(duration.glyphs.map(\.text).joined() == "10:45")
        #expect(raw.glyphs.map(\.text).joined() == "RAW")
    }

    @Test func rawUsesFixedPhotosSizeAndAHardCompactGridCutoff() throws {
        let normal = try #require(
            GridThumbnailOverlayPolicy.layouts(
                for: GridThumbnailOverlay(showsRAW: true),
                in: CGRect(x: 0, y: 0, width: 72, height: 72)
            ).first
        )
        let large = try #require(
            GridThumbnailOverlayPolicy.layouts(
                for: GridThumbnailOverlay(showsRAW: true),
                in: CGRect(x: 0, y: 0, width: 320, height: 320)
            ).first
        )
        let compact = GridThumbnailOverlayPolicy.layouts(
            for: GridThumbnailOverlay(showsRAW: true),
            in: CGRect(x: 0, y: 0, width: 64, height: 64)
        )

        #expect(normal.kind == .raw)
        #expect(normal.backgroundRect.height == 20)
        #expect(large.backgroundRect.height == 20)
        #expect(normal.glyphs.allSatisfy { $0.rect.height == 13 })
        #expect(large.glyphs.allSatisfy { $0.rect.height == 13 })
        #expect(normal.alpha == 1)
        #expect(large.alpha == 1)
        #expect(compact.isEmpty)
    }

    @Test func bottomTrailingObstructionMovesDurationLeftWithoutMovingRAW() throws {
        let displayed = CGRect(x: 0, y: 0, width: 120, height: 120)
        let overlay = GridThumbnailOverlay(durationText: "0:42", showsRAW: true)
        let clear = GridThumbnailOverlayPolicy.layouts(
            for: overlay,
            in: displayed
        )
        let obstructed = GridThumbnailOverlayPolicy.layouts(
            for: overlay,
            in: displayed,
            bottomTrailingInset: 28
        )
        let clearDuration = try #require(clear.first { $0.kind == .duration })
        let shiftedDuration = try #require(obstructed.first { $0.kind == .duration })
        let clearRAW = try #require(clear.first { $0.kind == .raw })
        let shiftedRAW = try #require(obstructed.first { $0.kind == .raw })

        #expect(abs(shiftedDuration.backgroundRect.maxX - (clearDuration.backgroundRect.maxX - 28)) < 0.001)
        #expect(shiftedRAW.backgroundRect == clearRAW.backgroundRect)
    }

    @Test func labelsHideBeforeDenseThumbnailTextBecomesUnreadable() {
        let dense = CGRect(x: 0, y: 0, width: 52, height: 52)
        let layouts = GridThumbnailOverlayPolicy.layouts(
            for: GridThumbnailOverlay(durationText: "10:45", showsRAW: true),
            in: dense
        )
        #expect(layouts.isEmpty)
    }

    @Test func durationUsesFixedPhotosSizeAndAHardCompactGridCutoff() throws {
        let normal = try #require(
            GridThumbnailOverlayPolicy.layouts(
                for: GridThumbnailOverlay(durationText: "1:14"),
                in: CGRect(x: 0, y: 0, width: 72, height: 72)
            ).first
        )
        let large = try #require(
            GridThumbnailOverlayPolicy.layouts(
                for: GridThumbnailOverlay(durationText: "1:14"),
                in: CGRect(x: 0, y: 0, width: 320, height: 320)
            ).first
        )
        let compact = GridThumbnailOverlayPolicy.layouts(
            for: GridThumbnailOverlay(durationText: "1:14"),
            in: CGRect(x: 0, y: 0, width: 64, height: 64)
        )

        #expect(normal.backgroundRect.height == 20)
        #expect(large.backgroundRect.height == 20)
        #expect(normal.alpha == 1)
        #expect(large.alpha == 1)
        #expect(normal.backgroundRect.maxX == 72)
        #expect(normal.backgroundRect.maxY == 72)
        #expect(compact.isEmpty)
    }

    @Test func representativeTenMinuteDurationFitsWithoutClippingAtReadableSize() throws {
        let thumbnail = CGRect(x: 0, y: 0, width: 68, height: 68)
        let layout = try #require(
            GridThumbnailOverlayPolicy.layouts(
                for: GridThumbnailOverlay(durationText: "10:45"),
                in: thumbnail
            ).first
        )
        #expect(layout.alpha == 1)
        #expect(thumbnail.contains(layout.backgroundRect))
        #expect(layout.glyphs.allSatisfy { layout.backgroundRect.contains($0.rect) })
    }

    @Test func longDurationHidesInsteadOfOverflowingThumbnail() {
        let thumbnail = CGRect(x: 0, y: 0, width: 80, height: 80)
        let layouts = GridThumbnailOverlayPolicy.layouts(
            for: GridThumbnailOverlay(durationText: "123:45:67"),
            in: thumbnail
        )
        #expect(layouts.isEmpty)
    }

    @Test func labelPositionTracksInterpolatedDisplayedRectRatherThanOuterSlot() throws {
        let fitted = CGRect(x: 0, y: 14, width: 100, height: 72)
        let square = CGRect(x: 0, y: 0, width: 100, height: 100)
        let overlay = GridThumbnailOverlay(durationText: "0:42", showsRAW: true)

        let fittedLayouts = GridThumbnailOverlayPolicy.layouts(
            for: overlay,
            in: fitted
        )
        let squareLayouts = GridThumbnailOverlayPolicy.layouts(
            for: overlay,
            in: square
        )
        let fittedDuration = try #require(fittedLayouts.first { $0.kind == .duration })
        let squareDuration = try #require(squareLayouts.first { $0.kind == .duration })
        let fittedRAW = try #require(fittedLayouts.first { $0.kind == .raw })
        let squareRAW = try #require(squareLayouts.first { $0.kind == .raw })

        #expect(fittedDuration.backgroundRect.maxY < squareDuration.backgroundRect.maxY)
        #expect(fitted.contains(fittedDuration.backgroundRect))
        #expect(fittedRAW.backgroundRect.minY > squareRAW.backgroundRect.minY)
        #expect(fitted.contains(fittedRAW.backgroundRect))
        #expect(square.contains(squareRAW.backgroundRect))
    }
}
