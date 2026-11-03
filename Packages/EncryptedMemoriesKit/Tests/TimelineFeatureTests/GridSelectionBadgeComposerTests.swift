import CoreGraphics
import GridCore
import Metal
import MetalGridComposeCore
import MetalGridTextureAppKitAdapter
import MetalGridTextureCore
import MetalRenderingCore
import PhotosCore
import Testing
import TimelineCore

@Suite @MainActor struct GridSelectionBadgeComposerTests {
    private let band = CGRect(x: 0, y: 455, width: 669, height: 40)
    private let viewport = CGSize(width: 669, height: 951)
    private var regions: ReservedRegionLayout {
        ReservedRegionLayout(
            areas: [ReservedRegionArea(frame: band, isActive: true)],
            bounds: CGRect(x: 0, y: 80, width: 669, height: 790))
    }

    private func cache(sizes: [CGSize] = [CGSize(width: 64, height: 64)]) throws -> MetalGridTextureCache<Int> {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let cache: MetalGridTextureCache<Int> = try #require(
            MetalGridTextureCache(
                device: device,
                budget: GridTextureBudget(
                    maxUploadsPerFrame: 64, maxUploadBytesPerFrame: 64_000_000,
                    maxCachedTextures: 4096, maxResidentBytes: 256_000_000, overscanFraction: 1),
                maxTexturePixels: 64, glyphRasterizer: AppKitMetalGridGlyphRasterizer()))
        var images: [Int: CGImage] = [:]
        for (index, size) in sizes.enumerated() {
            let context = try #require(
                CGContext(
                    data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                    bytesPerRow: Int(size.width) * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            images[index] = try #require(context.makeImage())
        }
        let ids = Array(sizes.indices)
        cache.beginFrame(pinned: Set(ids))
        cache.uploadVisible(wanted: ids) { images[$0] }
        try #require(ids.allSatisfy { cache.isResident($0) }, "Use real resident thumbnails")
        return cache
    }

    private func badge(
        tile: CGRect, selected: Bool, regions: ReservedRegionLayout, cache: MetalGridTextureCache<Int>
    ) throws -> MetalGridQuad {
        let output = MetalGridFrameComposer.buildGroups(
            slots: [GridRenderSlot(index: 0, column: 0, row: 0, rect: tile)],
            flatUIDs: [0], cache: cache, displayMode: .squareFillCrop, cornerRadius: 11,
            decorations: MetalGridDecorations(
                accent: SIMD4(0, 0, 1, 1), accentGlyphColor: .white, selectionMode: true,
                selected: selected ? [0] : [], favorites: [], overlay: { _ in .empty },
                reservedRegions: regions))
        return try #require(output.groups.last?.quads.last)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func realComposerKeepsFilledAndEmptyCirclesFullClearAndAtEdgesAtEveryLevel() throws {
        let cache = try cache()
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
        let engine = SquareTileGridEngine(sectionCounts: [4_000], profile: profile, fillOrder: .newestBottomTrailing)
        for level in profile.levels.indices {
            let geometry = engine.resolvedMetrics(level: level, width: viewport.width)
            for selected in [false, true] {
                let flatTile = CGRect(x: 100, y: 90, width: geometry.slotSide, height: geometry.slotSide)
                let normal = try badge(tile: flatTile, selected: selected, regions: .none, cache: cache)
                for y in stride(from: 90.0, through: 800.0 - geometry.slotSide, by: 3) {
                    let tile = CGRect(x: 100, y: y, width: geometry.slotSide, height: geometry.slotSide)
                    let mark = try badge(tile: tile, selected: selected, regions: regions, cache: cache)
                    #expect(mark.rect.size == normal.rect.size)
                    #expect(mark.rect.width == mark.rect.height)
                    #expect(mark.uvMin == SIMD2<Float>(0, 0))
                    #expect(mark.uvMax == SIMD2<Float>(1, 1))
                    #expect(mark.alpha == 1)
                    #expect(regions.bounds.contains(mark.rect))
                    #expect(regions.isClear(mark.rect), "level=\(level), y=\(y), selected=\(selected)")
                    let middle = tile.insetBy(dx: tile.width * 0.3, dy: tile.height * 0.3)
                    #expect(!middle.contains(CGPoint(x: mark.rect.midX, y: mark.rect.midY)))
                }
            }
        }
    }
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func composerForwardsItsRealMetricsAndDrawsTheWholeMovingCircleAboveThePhoto() throws {
        let cache = try cache()
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
        let engine = SquareTileGridEngine(sectionCounts: [4_000], profile: profile, fillOrder: .newestBottomTrailing)
        for level in [0, 3, 5] {
            for selected in [false, true] {
                let metrics = engine.resolvedMetrics(level: level, width: viewport.width)
                let layout = GridSelectionBadgeLayout()
                var motion = GridSelectionBadgeMotion()
                var calls = 0
                var time = 0.0
                func compose(y: CGFloat) throws -> MetalGridQuad {
                    let tile = CGRect(x: 100, y: y, width: metrics.slotSide, height: metrics.slotSide)
                    let output = MetalGridFrameComposer.buildGroups(
                        slots: [GridRenderSlot(index: 0, column: 0, row: 0, rect: tile)],
                        flatUIDs: [0], cache: cache, displayMode: .squareFillCrop, cornerRadius: 11,
                        decorations: MetalGridDecorations(
                            accent: SIMD4(0, 0, 1, 1), accentGlyphColor: .white, selectionMode: true,
                            selected: selected ? [0] : [], favorites: [], overlay: { _ in .empty },
                            reservedRegions: regions, selectionBadgeLayout: layout,
                            selectionBadgeFrame: { _, frame, side, inset, regions, occupied, neighbors, row, layout in
                                calls += 1
                                return motion.frame(
                                    tile: frame, side: side, inset: inset, regions: regions, avoiding: occupied,
                                    neighboringTiles: neighbors, row: row, layout: layout, now: time,
                                    reduceMotion: false)
                            }))
                    return try #require(output.groups.last?.quads.last)
                }
                let normal = try compose(y: 90)
                time = 1
                let start = try compose(y: 430)
                time = 1.1
                let middle = try compose(y: 430)
                time = 1.21
                let end = try compose(y: 430)
                #expect(calls == 4, "The production composer must forward its actual sizing and frames")
                #expect(middle.rect != start.rect && middle.rect != end.rect)
                #expect(regions.isClear(end.rect))
                let tile = CGRect(x: 100, y: 430, width: metrics.slotSide, height: metrics.slotSide)
                for quad in [start, middle, end] {
                    #expect(quad.rect.size == normal.rect.size)
                    #expect(quad.rect.width == quad.rect.height)
                    #expect(tile.contains(quad.rect), "An available in-tile path stays in its own thumbnail")
                    #expect(quad.uvMin == SIMD2<Float>(0, 0) && quad.uvMax == SIMD2<Float>(1, 1))
                    #expect(quad.alpha == 1)
                }
                #expect(abs(middle.rect.midX - (start.rect.midX + end.rect.midX) / 2) < 0.001)
                #expect(abs(middle.rect.midY - (start.rect.midY + end.rect.midY) / 2) < 0.001)
            }
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func timedCoreRestingSlotsStayClearThroughoutTheRealProductionLadder() throws {
        let cache = try cache()
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
        let engine = SquareTileGridEngine(sectionCounts: [4_000], profile: profile, fillOrder: .newestBottomTrailing)
        for level in profile.levels.indices {
            let metrics = engine.resolvedMetrics(level: level, width: viewport.width)
            let reference = CGRect(x: 100, y: 90, width: metrics.slotSide, height: metrics.slotSide)
            let normal = try badge(tile: reference, selected: false, regions: .none, cache: cache)
            let side = normal.rect.width
            let inset = reference.maxY - normal.rect.maxY
            for reversed in [false, true] {
                var motion = GridSelectionBadgeMotion()
                let steps = Array(stride(from: 90.0, through: 800.0 - metrics.slotSide, by: 1))
                for (step, y) in (reversed ? steps.reversed().map { $0 } : steps).enumerated() {
                    let tile = CGRect(x: 100, y: y, width: metrics.slotSide, height: metrics.slotSide)
                    let neighbors = [
                        tile.offsetBy(dx: 0, dy: -metrics.pitch), tile.offsetBy(dx: 0, dy: metrics.pitch),
                    ]
                    let rect = motion.frame(
                        tile: tile, side: side, inset: inset, regions: regions,
                        neighboringTiles: neighbors, now: Double(step), reduceMotion: true)
                    #expect(regions.isClear(rect), "level=\(level), y=\(y), reverse=\(reversed)")
                    #expect(regions.bounds.contains(rect))
                    #expect(rect.size == normal.rect.size)
                    let middle = tile.insetBy(dx: tile.width * 0.3, dy: tile.height * 0.3)
                    #expect(!middle.contains(CGPoint(x: rect.midX, y: rect.midY)))
                    if !tile.contains(rect) {
                        for neighbor in neighbors {
                            let middle = neighbor.insetBy(dx: neighbor.width * 0.3, dy: neighbor.height * 0.3)
                            #expect(
                                !middle.contains(CGPoint(x: rect.midX, y: rect.midY)),
                                "The no-space exception must not enter a neighbouring thumbnail's middle")
                        }
                    }
                }
            }
        }
    }
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func normalScrollingOfTheProductionDenseFrameKeepsTheBadgeClear() throws {
        let cache = try cache()
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
        let engine = SquareTileGridEngine(sectionCounts: [4_000], profile: profile, fillOrder: .newestBottomTrailing)
        let plan = engine.framePlan(
            level: profile.levels.count - 1, viewportSize: viewport,
            scrollOffset: CGPoint(x: 0, y: 1012), overscan: 0)
        let witness = try #require(plan.visibleSlots.first { band.contains($0.viewportRect) })
        #expect(witness.index == 880)
        #expect(witness.viewportRect == CGRect(x: 0, y: 462, width: 32.5, height: 32.5))
        for selected in [false, true] {
            let circle = try badge(tile: witness.viewportRect, selected: selected, regions: regions, cache: cache)
            #expect(regions.isClear(circle.rect))
            #expect(regions.bounds.contains(circle.rect))
            #expect(circle.rect.width == circle.rect.height)
        }
    }
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func outerDisplayDenseCirclesUseEdgeInsetsWithoutChangingSizeOrDensity() throws {
        let cache = try cache()
        let width: CGFloat = 466
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: width, inputAffinity: .touch))
        let engine = SquareTileGridEngine(sectionCounts: [4_000], profile: profile, fillOrder: .newestBottomTrailing)
        let metrics = engine.resolvedMetrics(level: profile.levels.count - 1, width: width)
        #expect(metrics.slotSide == 22.35)
        let tile = CGRect(x: 100, y: 200, width: metrics.slotSide, height: metrics.slotSide)
        for selected in [false, true] {
            let quad = try badge(tile: tile, selected: selected, regions: .none, cache: cache)
            #expect(quad.rect.size == CGSize(width: 11, height: 11))
            #expect(tile.insetBy(dx: 0.5, dy: 0.5).contains(quad.rect))
            #expect(ReservedRegionLayout.markIsAtEdge(quad.rect, of: tile))
            #expect(quad.uvMin == SIMD2<Float>(0, 0) && quad.uvMax == SIMD2<Float>(1, 1))
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func theFineInsetAndTinyTileExceptionUseTheRealProductionLadder() throws {
        let cache = try cache()
        // Below 18.67pt, an 11pt circle with a 0.1pt inset cannot put its centre outside the inner 40%.
        let tinyTileThreshold: CGFloat = 18.67
        for width: CGFloat in [320, 393, 466, 669, 1024] {
            let profile = TimelineGridProfileConfiguration.production.resolver.profile(
                for: TimelineGridViewport(layoutWidth: width, inputAffinity: .touch))
            let engine = SquareTileGridEngine(
                sectionCounts: [4_000], profile: profile, fillOrder: .newestBottomTrailing)
            for level in profile.levels.indices {
                let metrics = engine.resolvedMetrics(level: level, width: width)
                let tile = CGRect(x: 100, y: 200, width: metrics.slotSide, height: metrics.slotSide)
                for selected in [false, true] {
                    let quad = try badge(tile: tile, selected: selected, regions: .none, cache: cache)
                    #expect(tile.contains(quad.rect), "The full circle must not be clipped")
                    let inset = tile.maxY - quad.rect.maxY
                    if metrics.slotSide < tinyTileThreshold {
                        #expect(inset == 3, "BESTAND: only impossible tiny tiles retain the established corner")
                        #expect(!ReservedRegionLayout.markIsAtEdge(quad.rect, of: tile))
                    } else {
                        #expect(inset >= 0.1 - 0.00001)
                        #expect(ReservedRegionLayout.markIsAtEdge(quad.rect, of: tile))
                        if metrics.slotSide >= 28.34 { #expect(inset >= 3) }
                    }
                    if width == 393 && level == profile.levels.count - 1 {
                        #expect(abs(inset - 0.109) < 0.00001)
                        #expect(quad.rect.size == CGSize(width: 11, height: 11))
                    }
                }
            }
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func realComposerMotionKeepsCirclesInsideEachZoomGeometry() throws {
        let cache = try cache()
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
        let engine = SquareTileGridEngine(sectionCounts: [4_000], profile: profile, fillOrder: .newestBottomTrailing)
        for selected in [false, true] {
            let layout = GridSelectionBadgeLayout()
            var motion = GridSelectionBadgeMotion()
            for (step, level) in [3, 5, 0, 5, 3].enumerated() {
                let metrics = engine.resolvedMetrics(level: level, width: viewport.width)
                let tile = CGRect(x: 100, y: 200, width: metrics.slotSide, height: metrics.slotSide)
                let normal = try badge(tile: tile, selected: selected, regions: .none, cache: cache)
                let output = MetalGridFrameComposer.buildGroups(
                    slots: [GridRenderSlot(index: 0, column: 0, row: 0, rect: tile)], flatUIDs: [0],
                    cache: cache, displayMode: .squareFillCrop, cornerRadius: 11,
                    decorations: MetalGridDecorations(
                        accent: SIMD4(0, 0, 1, 1), accentGlyphColor: .white, selectionMode: true,
                        selected: selected ? [0] : [], favorites: [], overlay: { _ in .empty },
                        selectionBadgeLayout: layout,
                        selectionBadgeFrame: { _, frame, side, inset, regions, occupied, neighbors, row, layout in
                            motion.frame(
                                tile: frame, side: side, inset: inset, regions: regions, avoiding: occupied,
                                neighboringTiles: neighbors, row: row, layout: layout, now: Double(step) * 0.05,
                                reduceMotion: false)
                        }))
                let circle = try #require(output.groups.last?.quads.last)
                #expect(circle.rect == normal.rect)
                #expect(tile.contains(circle.rect))
                #expect(!motion.isAnimating)
            }
        }
    }
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func aspectFitRowSwitchesTogetherDespiteDifferentThumbnailHeights() throws {
        let cache = try cache(sizes: [
            CGSize(width: 64, height: 64), CGSize(width: 64, height: 48), CGSize(width: 64, height: 36),
        ])
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
        let engine = SquareTileGridEngine(sectionCounts: [4_000], profile: profile, fillOrder: .newestBottomTrailing)
        let metrics = engine.resolvedMetrics(level: 1, width: viewport.width)
        for reversed in [false, true] {
            let layout = GridSelectionBadgeLayout()
            var motions = [GridSelectionBadgeMotion(), GridSelectionBadgeMotion(), GridSelectionBadgeMotion()]
            let entry = reversed ? band.maxY : band.minY - metrics.slotSide
            let ys: [CGFloat] =
                reversed
                ? [700, entry - 0.40 * metrics.slotSide, entry - 0.45 * metrics.slotSide, 700]
                : [90, entry + 8, entry + 40, 90]
            for (step, y) in ys.enumerated() {
                let slots = (0..<3).map {
                    GridRenderSlot(
                        index: $0, column: $0, row: 0,
                        rect: CGRect(
                            x: CGFloat($0) * metrics.pitch, y: y,
                            width: metrics.slotSide, height: metrics.slotSide))
                }
                let output = MetalGridFrameComposer.buildGroups(
                    slots: slots, flatUIDs: [0, 1, 2], cache: cache, displayMode: .aspectFitInsideSquare,
                    cornerRadius: 11,
                    decorations: MetalGridDecorations(
                        accent: SIMD4(0, 0, 1, 1), accentGlyphColor: .white, selectionMode: true,
                        selected: [0], favorites: [], overlay: { _ in .empty }, reservedRegions: regions,
                        selectionBadgeLayout: layout,
                        selectionBadgeFrame: { uid, tile, side, inset, regions, occupied, neighbors, row, layout in
                            motions[uid].frame(
                                tile: tile, side: side, inset: inset, regions: regions, avoiding: occupied,
                                neighboringTiles: neighbors, row: row, layout: layout, now: Double(step),
                                reduceMotion: true)
                        }))
                #expect(
                    Set(motions.map(\.usesAlternate)).count == 1,
                    "One row must switch together: reverse=\(reversed), y=\(y)")
                for group in output.groups where group.quads.first?.rect.width == 22 {
                    for quad in group.quads { #expect(regions.isClear(quad.rect)) }
                }
            }
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func denseScrollFrameKeepsTheNoSpaceSearchWithinOneFrameBudget() throws {
        let cache = try cache()
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
        let engine = SquareTileGridEngine(sectionCounts: [4_000], profile: profile, fillOrder: .newestBottomTrailing)
        var motions: [Int: GridSelectionBadgeMotion] = [:]
        let clock = ContinuousClock()
        let layout = GridSelectionBadgeLayout()
        var measurements: [Double] = []
        var noSpaceCount = 0
        for step in 0..<4 {
            let plan = engine.framePlan(
                level: profile.levels.count - 1, viewportSize: viewport,
                scrollOffset: CGPoint(x: 0, y: 1012 + step), overscan: 0)
            let slots = plan.visibleSlots.map {
                GridRenderSlot(index: $0.index, column: $0.column, row: $0.row, rect: $0.viewportRect)
            }
            noSpaceCount = plan.visibleSlots.filter { band.contains($0.viewportRect) }.count
            var searchMilliseconds = 0.0
            let start = clock.now
            let output = MetalGridFrameComposer.buildGroups(
                slots: slots, flatUIDs: Array(0..<4_000), cache: cache, displayMode: .squareFillCrop,
                cornerRadius: 11,
                decorations: MetalGridDecorations(
                    accent: SIMD4(0, 0, 1, 1), accentGlyphColor: .white, selectionMode: true,
                    selected: [], favorites: [], overlay: { _ in .empty }, reservedRegions: regions,
                    selectionBadgeLayout: layout,
                    selectionBadgeFrame: { uid, tile, side, inset, regions, occupied, neighbors, row, layout in
                        var motion = motions[uid] ?? GridSelectionBadgeMotion()
                        let searchStart = clock.now
                        let result = motion.frame(
                            tile: tile, side: side, inset: inset, regions: regions, avoiding: occupied,
                            neighboringTiles: neighbors, row: row, layout: layout, now: Double(step), reduceMotion: true
                        )
                        if band.contains(tile) {
                            let elapsed = searchStart.duration(to: clock.now).components
                            searchMilliseconds +=
                                Double(elapsed.seconds) * 1_000
                                + Double(elapsed.attoseconds) / 1e15
                        }
                        motions[uid] = motion
                        return result
                    }))
            let elapsed = start.duration(to: clock.now).components
            let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
            if step > 0 { measurements.append(milliseconds) }
            print(
                "DENSE_FRAME sample=\(step) slots=\(slots.count) noSpace=\(noSpaceCount) wallMs=\(milliseconds) noSpaceSearchMs=\(searchMilliseconds)"
            )
            #expect(!output.groups.isEmpty)
        }
        #expect(layout.preparationCount == 1, "Scrolling within one visible-row bucket reuses prepared facts")
        #expect(noSpaceCount == 20, "The measurement must include one full no-space row")
        let average = measurements.reduce(0, +) / Double(measurements.count)
        print("DENSE_FRAME meanMs=\(average)")
        #expect(average < 1000.0 / 60.0, "A warmed dense scroll frame must fit the 60Hz budget")
    }
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func preparedGeometryReusesScrollTranslationsAndInvalidatesRowBandAndSizeChanges() throws {
        let cache = try cache()
        let layout = GridSelectionBadgeLayout()
        func compose(width: CGFloat, offset: CGFloat, band: CGRect) {
            let viewport = CGSize(width: width, height: 951)
            let profile = TimelineGridProfileConfiguration.production.resolver.profile(
                for: TimelineGridViewport(layoutWidth: width, inputAffinity: .touch))
            let engine = SquareTileGridEngine(
                sectionCounts: [4_000], profile: profile, fillOrder: .newestBottomTrailing)
            let plan = engine.framePlan(
                level: profile.levels.count - 1, viewportSize: viewport,
                scrollOffset: CGPoint(x: 0, y: offset), overscan: 0)
            _ = MetalGridFrameComposer.buildGroups(
                slots: plan.visibleSlots.map {
                    GridRenderSlot(index: $0.index, column: $0.column, row: $0.row, rect: $0.viewportRect)
                }, flatUIDs: Array(0..<4_000), cache: cache, displayMode: .squareFillCrop, cornerRadius: 11,
                decorations: MetalGridDecorations(
                    accent: SIMD4(0, 0, 1, 1), accentGlyphColor: .white, selectionMode: true,
                    selected: [], favorites: [], overlay: { _ in .empty },
                    reservedRegions: ReservedRegionLayout(
                        areas: [ReservedRegionArea(frame: band, isActive: true)],
                        bounds: CGRect(origin: .zero, size: viewport)), selectionBadgeLayout: layout))
        }
        compose(width: 669, offset: 1012, band: band)
        #expect(layout.preparationCount == 1)
        compose(width: 669, offset: 1012.25, band: band)
        #expect(layout.preparationCount == 1, "A fractional scroll translates the cached row facts")
        compose(width: 669, offset: 1013, band: band)
        #expect(layout.preparationCount == 1)
        compose(width: 669, offset: 1046, band: band)
        #expect(layout.preparationCount == 2, "A newly visible row invalidates the row bucket")
        let changedBand = band.offsetBy(dx: 0, dy: 10)
        compose(width: 669, offset: 1046, band: changedBand)
        #expect(layout.preparationCount == 3, "A changed band invalidates candidates and row facts")
        compose(width: 466, offset: 1046, band: CGRect(x: 0, y: 465, width: 466, height: 40))
        #expect(layout.preparationCount == 4, "Changed tile size and usable geometry invalidate the cache")
    }
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func aStoppedRowKeepsOneDecisionWhileItsAspectFitThumbnailsArrive() throws {
        let cache = try cache(sizes: [])
        let context = try #require(
            CGContext(
                data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 256,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
        let engine = SquareTileGridEngine(sectionCounts: [4_000], profile: profile, fillOrder: .newestBottomTrailing)
        let metrics = engine.resolvedMetrics(level: 1, width: viewport.width)
        var motions = [GridSelectionBadgeMotion(), GridSelectionBadgeMotion(), GridSelectionBadgeMotion()]
        var homes = Array(repeating: CGRect.zero, count: 3)
        let layout = GridSelectionBadgeLayout()
        for step in 0..<5 {
            if step >= 2 {
                let uid = step - 2
                cache.beginFrame(pinned: [0, 1, 2])
                cache.uploadVisible(wanted: [uid]) { _ in image }
                #expect(cache.isResident(uid), "A real landscape texture must replace its square placeholder")
            }
            let y: CGFloat = step == 0 ? 90 : band.minY - metrics.slotSide + 8
            _ = MetalGridFrameComposer.buildGroups(
                slots: (0..<3).map {
                    GridRenderSlot(
                        index: $0, column: $0, row: 0,
                        rect: CGRect(
                            x: CGFloat($0) * metrics.pitch, y: y,
                            width: metrics.slotSide, height: metrics.slotSide))
                }, flatUIDs: [0, 1, 2], cache: cache, displayMode: .aspectFitInsideSquare, cornerRadius: 11,
                decorations: MetalGridDecorations(
                    accent: SIMD4(0, 0, 1, 1), accentGlyphColor: .white, selectionMode: true,
                    selected: [0], favorites: [], overlay: { _ in .empty }, reservedRegions: regions,
                    selectionBadgeLayout: layout,
                    selectionBadgeFrame: { uid, tile, side, inset, regions, occupied, neighbors, row, layout in
                        homes[uid] = ReservedRegionLayout.homeMarkRect(in: tile, side: side, inset: inset)
                        return motions[uid].frame(
                            tile: tile, side: side, inset: inset, regions: regions, avoiding: occupied,
                            neighboringTiles: neighbors, row: row, layout: layout,
                            now: Double(step), reduceMotion: true)
                    }))
            #expect(
                Set(motions.map(\.usesAlternate)).count == 1,
                "A stopped row cannot split its switch decision on arrival")
            if step > 0 {
                #expect(
                    motions.allSatisfy { $0.usesAlternate }, "Holding still inside hysteresis keeps the row's decision")
                for uid in 0..<3 { #expect(motions[uid].target != homes[uid]) }
            }
        }
    }
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func realComposerContinuedReversalKeepsEveryReleasedCircleHome() throws {
        try verifyContinuedReversal(jumping: false)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func realComposerOneFrameCrossingStartsTheNextEntryFromTheCorrectEdge() throws {
        try verifyContinuedReversal(jumping: true)
    }

    private func verifyContinuedReversal(jumping: Bool) throws {
        let cache = try cache(sizes: Array(repeating: CGSize(width: 64, height: 64), count: 40))
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
        let engine = SquareTileGridEngine(sectionCounts: [4_000], profile: profile, fillOrder: .newestBottomTrailing)
        for level in profile.levels.indices {
            let metrics = engine.resolvedMetrics(level: level, width: viewport.width)
            let initial = engine.framePlan(level: level, viewportSize: viewport, scrollOffset: .zero, overscan: 0)
            let row = try #require(initial.visibleSlots.first { $0.column == 0 && $0.row > 0 })
            let rowSlots = initial.visibleSlots.filter { $0.row == row.row }
            try #require(rowSlots.count == metrics.columns)
            for selected in [false, true] {
                var motions: [Int: GridSelectionBadgeMotion] = [:]
                var homes: [Int: CGRect] = [:]
                let layout = GridSelectionBadgeLayout()
                var time = 0.0
                func step(y: CGFloat, alternate: Bool, crossingSide: Bool = true) {
                    var offset = row.slotRect.minY - y
                    // Keep the inclusive switch sample across the line after viewport-coordinate rounding.
                    let belowSwitchLine = band.maxY - metrics.slotSide * 0.4
                    if y == belowSwitchLine { offset = crossingSide ? offset.nextUp : offset.nextDown }
                    if y == band.minY - metrics.slotSide + metrics.slotSide * 0.4 { offset = offset.nextDown }
                    let plan = engine.framePlan(
                        level: level, viewportSize: viewport,
                        scrollOffset: CGPoint(x: 0, y: offset), overscan: 0)
                    let slots = plan.visibleSlots.filter { $0.row == row.row }.map {
                        GridRenderSlot(index: $0.index, column: $0.column, row: $0.row, rect: $0.viewportRect)
                    }
                    #expect(slots.count == metrics.columns)
                    #expect(slots.allSatisfy { abs($0.rect.minY - y) < 0.000_000_001 })
                    if y == belowSwitchLine {
                        #expect(slots.allSatisfy { crossingSide ? $0.rect.minY <= y : $0.rect.minY > y })
                    }
                    _ = MetalGridFrameComposer.buildGroups(
                        slots: slots, flatUIDs: Array(0..<4_000), cache: cache, displayMode: .squareFillCrop,
                        cornerRadius: 11,
                        decorations: MetalGridDecorations(
                            accent: SIMD4(0, 0, 1, 1), accentGlyphColor: .white, selectionMode: true,
                            selected: selected ? Set(rowSlots.map(\.index)) : [], favorites: [],
                            overlay: { _ in .empty },
                            reservedRegions: regions, selectionBadgeLayout: layout,
                            selectionBadgeFrame: { uid, tile, side, inset, regions, occupied, neighbors, row, layout in
                                homes[uid] = ReservedRegionLayout.homeMarkRect(in: tile, side: side, inset: inset)
                                var motion = motions[uid] ?? GridSelectionBadgeMotion()
                                let rect = motion.frame(
                                    tile: tile, side: side, inset: inset, regions: regions, avoiding: occupied,
                                    neighboringTiles: neighbors, row: row, layout: layout, now: time, reduceMotion: true
                                )
                                motions[uid] = motion
                                return rect
                            }))
                    time += 1
                    #expect(motions.count == metrics.columns)
                    #expect(
                        motions.values.allSatisfy { $0.usesAlternate == alternate },
                        "level=\(level), y=\(y), jumping=\(jumping), selected=\(selected)")
                    if !alternate {
                        #expect(
                            motions.allSatisfy { homes[$0.key] == $0.value.target },
                            "A released row must keep every full circle in its normal slot")
                    }
                }
                let above = band.minY - metrics.slotSide - 20
                let below = band.maxY + 20
                if jumping {
                    step(y: above, alternate: false)
                    step(y: band.minY - metrics.slotSide + metrics.slotSide * 0.001, alternate: false)
                    step(y: below, alternate: false)
                    step(y: band.maxY - metrics.slotSide * 0.399, alternate: false)
                    if metrics.columns == 7 {
                        step(y: band.maxY - metrics.slotSide * 0.4, alternate: false, crossingSide: false)
                    }
                    step(y: band.maxY - metrics.slotSide * 0.4, alternate: true)
                    step(y: above, alternate: false)
                    step(y: band.minY - metrics.slotSide + metrics.slotSide * 0.001, alternate: false)
                    step(y: band.minY - metrics.slotSide + metrics.slotSide * 0.4, alternate: true)
                } else {
                    step(y: below, alternate: false)
                    if metrics.columns == 7 {
                        step(y: band.maxY - metrics.slotSide * 0.4, alternate: false, crossingSide: false)
                    }
                    step(y: band.maxY - metrics.slotSide * 0.4, alternate: true)
                    let release = 0.4 - max(0.1, 4 / metrics.slotSide) - 0.001
                    for share in [release, release - 0.01, release - 0.02, 0.1, 0.05, 0, -0.01] {
                        step(y: band.maxY - metrics.slotSide * share, alternate: false)
                    }
                }
            }
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func aSubQuantumRowHeightChangeKeepsHysteresisAndThePreparedCache() throws {
        let cache = try cache(sizes: Array(repeating: CGSize(width: 64, height: 64), count: 40))
        let profile = TimelineGridProfileConfiguration.production.resolver.profile(
            for: TimelineGridViewport(layoutWidth: viewport.width, inputAffinity: .touch))
        let engine = SquareTileGridEngine(sectionCounts: [3_600], profile: profile, fillOrder: .newestBottomTrailing)
        let plan = engine.framePlan(level: 3, viewportSize: viewport, scrollOffset: .zero, overscan: 0)
        let first = try #require(plan.visibleSlots.first { $0.column == 0 && $0.row > 0 })
        let row = plan.visibleSlots.filter { $0.row == first.row }
        try #require(row.count == 7)
        let layout = GridSelectionBadgeLayout()
        var motions: [Int: GridSelectionBadgeMotion] = [:]
        var time = 0.0
        func step(share: CGFloat, heightChange: CGFloat = 0, alternate: Bool) {
            let slots = row.map { slot in
                GridRenderSlot(
                    index: slot.index, column: slot.column, row: slot.row,
                    rect: CGRect(
                        x: slot.viewportRect.minX, y: band.maxY - first.slotRect.height * share,
                        width: slot.viewportRect.width, height: slot.viewportRect.height + heightChange))
            }
            _ = MetalGridFrameComposer.buildGroups(
                slots: slots, flatUIDs: Array(0..<3_600), cache: cache, displayMode: .squareFillCrop,
                cornerRadius: 11,
                decorations: MetalGridDecorations(
                    accent: SIMD4(0, 0, 1, 1), accentGlyphColor: .white, selectionMode: true,
                    selected: [], favorites: [], overlay: { _ in .empty }, reservedRegions: regions,
                    selectionBadgeLayout: layout,
                    selectionBadgeFrame: { uid, tile, side, inset, regions, occupied, neighbors, row, layout in
                        var motion = motions[uid] ?? GridSelectionBadgeMotion()
                        _ = motion.frame(
                            tile: tile, side: side, inset: inset, regions: regions, avoiding: occupied,
                            neighboringTiles: neighbors, row: row, layout: layout, now: time, reduceMotion: true)
                        motions[uid] = motion
                        return motion.target
                    }))
            time += 1
            #expect(motions.count == 7)
            #expect(motions.values.allSatisfy { $0.usesAlternate == alternate })
        }
        step(share: -0.05, alternate: false)
        step(share: 0.41, alternate: true)
        step(share: 0.35, alternate: true)
        let preparations = layout.preparationCount
        for change in [0.000_000_1, 0.000_000_2, 0, 0.000_000_1, 0] {
            step(share: 0.35, heightChange: change, alternate: true)
            #expect(layout.preparationCount == preparations)
        }
    }
}
