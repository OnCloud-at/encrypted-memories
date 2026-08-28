import Testing

@testable import DesignSystemCore

@Suite struct TipJarProductAvailabilityTests {
    @Test func keepsAvailableProductsInConfiguredOrder() {
        let ordered = TipJarProductAvailability.orderedAvailableIdentifiers(
            expected: ["small", "medium", "large", "extra_large"],
            returned: ["extra_large", "large", "medium"]
        )

        #expect(ordered == ["medium", "large", "extra_large"])
    }

    @Test func returnsEmptyWhenStoreKitFindsNoConfiguredProduct() {
        let ordered = TipJarProductAvailability.orderedAvailableIdentifiers(
            expected: ["small", "medium"],
            returned: []
        )

        #expect(ordered.isEmpty)
    }
}
