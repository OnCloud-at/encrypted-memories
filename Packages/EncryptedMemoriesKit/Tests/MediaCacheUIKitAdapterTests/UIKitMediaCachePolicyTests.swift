import Foundation
import Testing

@testable import MediaCacheUIKitAdapter

/// Deterministic iOS/iPadOS budget-policy tests: exact budgets for the 4/6/8/12 GB device classes, the clamp
/// edges, the constrained-memory decoded curve, and the dynamic-headroom cap. Physical/available memory are
/// injected, so nothing here depends on the machine running the tests.
@Suite struct UIKitMediaCachePolicyTests {
    private let bytesPerGiB: UInt64 = 1024 * 1024 * 1024
    private let bytesPerMiB: UInt64 = 1024 * 1024

    @Test func memoryClassSplitsAtFourPointFiveGiB() {
        #expect(UIKitMediaCachePolicy.memoryClass(physicalMemory: 4 * bytesPerGiB) == .constrained)
        // Physical memory can be lower than the marketed device capacity.
        #expect(
            UIKitMediaCachePolicy.memoryClass(physicalMemory: UInt64(3.7 * Double(bytesPerGiB))) == .constrained)
        #expect(
            UIKitMediaCachePolicy.memoryClass(physicalMemory: UInt64(4.5 * Double(bytesPerGiB))) == .constrained)
        #expect(
            UIKitMediaCachePolicy.memoryClass(physicalMemory: UInt64(4.5 * Double(bytesPerGiB)) + 1) == .standard)
        #expect(UIKitMediaCachePolicy.memoryClass(physicalMemory: 6 * bytesPerGiB) == .standard)
        #expect(UIKitMediaCachePolicy.memoryClass(physicalMemory: 12 * bytesPerGiB) == .standard)
    }

    @Test func byteRAMBudgetForDeviceClasses() {
        #expect(UIKitMediaCachePolicy.dataMemoryBudgetBytes(physicalMemory: 4 * bytesPerGiB) == 42_949_672)
        #expect(UIKitMediaCachePolicy.dataMemoryBudgetBytes(physicalMemory: 6 * bytesPerGiB) == 64_424_509)
        #expect(UIKitMediaCachePolicy.dataMemoryBudgetBytes(physicalMemory: 8 * bytesPerGiB) == 85_899_345)
        #expect(UIKitMediaCachePolicy.dataMemoryBudgetBytes(physicalMemory: 12 * bytesPerGiB) == 128_849_018)
    }

    @Test func byteRAMBudgetClampEdges() {
        #expect(UIKitMediaCachePolicy.dataMemoryBudgetBytes(physicalMemory: 2 * bytesPerGiB) == 32 * bytesPerMiB)
        #expect(UIKitMediaCachePolicy.dataMemoryBudgetBytes(physicalMemory: 64 * bytesPerGiB) == 512 * bytesPerMiB)
    }

    @Test func decodedRAMBudgetOnConstrainedFourGiBIsCappedAt224MiB() {
        let fourGiB = UIKitMediaCachePolicy.decodedRAMBudgetBytes(
            physicalMemory: 4 * bytesPerGiB, availableMemoryBytes: nil)
        #expect(fourGiB == 224 * bytesPerMiB)

        // The curve keeps lower reported capacities inside the target window.
        let reported = UIKitMediaCachePolicy.decodedRAMBudgetBytes(
            physicalMemory: UInt64(3.5 * Double(bytesPerGiB)), availableMemoryBytes: nil)
        #expect(reported == 206_695_301)
        #expect(reported >= 96 * bytesPerMiB && reported <= 224 * bytesPerMiB)
    }

    @Test func decodedRAMBudgetOnStandardDevicesKeepsProportionalEightPercent() {
        #expect(
            UIKitMediaCachePolicy.decodedRAMBudgetBytes(physicalMemory: 6 * bytesPerGiB, availableMemoryBytes: nil)
                == 515_396_075)
        #expect(
            UIKitMediaCachePolicy.decodedRAMBudgetBytes(physicalMemory: 8 * bytesPerGiB, availableMemoryBytes: nil)
                == 687_194_767)
        #expect(
            UIKitMediaCachePolicy.decodedRAMBudgetBytes(physicalMemory: 12 * bytesPerGiB, availableMemoryBytes: nil)
                == 1_030_792_151)
    }

    @Test func decodedRAMBudgetClampEdges() {
        #expect(
            UIKitMediaCachePolicy.decodedRAMBudgetBytes(physicalMemory: bytesPerGiB, availableMemoryBytes: nil)
                == 96 * bytesPerMiB)
        #expect(
            UIKitMediaCachePolicy.decodedRAMBudgetBytes(physicalMemory: 2 * bytesPerGiB, availableMemoryBytes: nil)
                == 118_111_600)
        #expect(
            UIKitMediaCachePolicy.decodedRAMBudgetBytes(physicalMemory: 16 * bytesPerGiB, availableMemoryBytes: nil)
                == 1024 * bytesPerMiB)
    }

    @Test func decodedRAMBudgetHonorsDynamicHeadroom() {
        let tight = UIKitMediaCachePolicy.decodedRAMBudgetBytes(
            physicalMemory: 4 * bytesPerGiB, availableMemoryBytes: 300 * bytesPerMiB)
        #expect(tight == 150 * bytesPerMiB)
        let veryTight = UIKitMediaCachePolicy.decodedRAMBudgetBytes(
            physicalMemory: 4 * bytesPerGiB, availableMemoryBytes: 120 * bytesPerMiB)
        #expect(veryTight == 96 * bytesPerMiB)
        #expect(
            UIKitMediaCachePolicy.decodedRAMBudgetBytes(
                physicalMemory: 4 * bytesPerGiB, availableMemoryBytes: 8 * bytesPerGiB) == 224 * bytesPerMiB)
        #expect(
            UIKitMediaCachePolicy.decodedRAMBudgetBytes(
                physicalMemory: 4 * bytesPerGiB, availableMemoryBytes: nil) == 224 * bytesPerMiB)
        // Zero means that no memory reading is available.
        #expect(
            UIKitMediaCachePolicy.decodedRAMBudgetBytes(
                physicalMemory: 4 * bytesPerGiB, availableMemoryBytes: 0) == 224 * bytesPerMiB)
    }

    @Test func wrapperRAMBudgetForDeviceClassesAndClampEdges() {
        #expect(UIKitMediaCachePolicy.wrapperRAMBudgetBytes(physicalMemory: 4 * bytesPerGiB) == 10_737_418)
        #expect(UIKitMediaCachePolicy.wrapperRAMBudgetBytes(physicalMemory: 6 * bytesPerGiB) == 16_106_127)
        #expect(UIKitMediaCachePolicy.wrapperRAMBudgetBytes(physicalMemory: 8 * bytesPerGiB) == 21_474_836)
        #expect(UIKitMediaCachePolicy.wrapperRAMBudgetBytes(physicalMemory: 12 * bytesPerGiB) == 32_212_254)
        #expect(
            UIKitMediaCachePolicy.wrapperRAMBudgetBytes(physicalMemory: 2 * bytesPerGiB) == 8 * bytesPerMiB)
        #expect(
            UIKitMediaCachePolicy.wrapperRAMBudgetBytes(physicalMemory: 64 * bytesPerGiB) == 48 * bytesPerMiB)
    }
}
