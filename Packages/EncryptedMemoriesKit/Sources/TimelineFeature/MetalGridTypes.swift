import CoreGraphics
import Foundation
import GridCore

// MARK: - Metal grid shared value types
//
// Per-frame render accounting for the Metal-backed photo grid. The scroll host owns
// physics, and the viewport-sized MTKView draws visible items through the texture cache.

#if DEBUG
    /// Per-frame render accounting for the `[MetalGridPerf]` diagnostics block.
    struct MetalGridStats {
        var visibleItems = 0
        var overscanItems = 0
        var realTextureItems = 0
        var placeholderItems = 0
        var textureUploads = 0
        var textureUploadBytes = 0
        var deferredTextureUploads = 0
        var evictions = 0
        var evictMs: Double = 0
        var residentTextureCount = 0
        var pinnedTextureCount = 0
        var textureCapacity = 0
        var pinnedTextureOverflow = false
        var residentByteBudget = 0
        var uploadByteBudget = 0
        var byteBudgetOverflow = false
        var residencySaturated = false
        var encodedSlotItems = 0
        var drawCalls = 0
        var textureBinds = 0
        var instanceCount = 0
        var textureUploadMs: Double = 0
        var drawMs: Double = 0
        var gpuMs: Double = 0
        var memoryEstimateBytes = 0

        static func frame(
            visibleCount: Int,
            overscanCount: Int,
            realCount: Int,
            cellCount: Int,
            textureUploads: Int,
            textureUploadBytes: Int,
            deferredTextureUploads: Int,
            textureUploadMs: Double,
            evictions: Int,
            evictMs: Double,
            residentBytes: Int,
            residentTextureCount: Int,
            pinnedTextureCount: Int,
            textureCapacity: Int,
            pinnedTextureOverflow: Bool,
            residentByteBudget: Int,
            uploadByteBudget: Int,
            byteBudgetOverflow: Bool,
            residencySaturated: Bool,
            drawCalls: Int,
            textureBinds: Int,
            instanceCount: Int,
            drawMs: Double,
            gpuMs: Double
        ) -> MetalGridStats {
            var stats = MetalGridStats()
            stats.visibleItems = visibleCount
            stats.overscanItems = overscanCount
            stats.realTextureItems = realCount
            stats.placeholderItems = max(0, cellCount - realCount)
            stats.encodedSlotItems = cellCount
            stats.textureUploads = textureUploads
            stats.textureUploadBytes = textureUploadBytes
            stats.deferredTextureUploads = deferredTextureUploads
            stats.textureUploadMs = textureUploadMs
            stats.evictions = evictions
            stats.evictMs = evictMs
            stats.memoryEstimateBytes = residentBytes
            stats.residentTextureCount = residentTextureCount
            stats.pinnedTextureCount = pinnedTextureCount
            stats.textureCapacity = textureCapacity
            stats.pinnedTextureOverflow = pinnedTextureOverflow
            stats.residentByteBudget = residentByteBudget
            stats.uploadByteBudget = uploadByteBudget
            stats.byteBudgetOverflow = byteBudgetOverflow
            stats.residencySaturated = residencySaturated
            stats.drawCalls = drawCalls
            stats.textureBinds = textureBinds
            stats.instanceCount = instanceCount
            stats.drawMs = drawMs
            stats.gpuMs = gpuMs
            return stats
        }
    }
#endif

typealias MetalGridBudget = GridTextureBudget
