import Testing

@testable import PhotosCore

@Suite("Tip jar products")
struct TipJarProductTests {
    @Test("Identifiers are stable, unique, and scoped to the application")
    func identifiersAreScoped() {
        let bundleIdentifier = "at.oncloud.encryptedmemories"
        let identifiers = TipJarProduct.identifiers(bundleIdentifier: bundleIdentifier)

        #expect(
            identifiers == [
                "at.oncloud.encryptedmemories.tip.s",
                "at.oncloud.encryptedmemories.tip.medium",
                "at.oncloud.encryptedmemories.tip.large",
                "at.oncloud.encryptedmemories.tip.extra_large",
            ])
        #expect(Set(identifiers).count == TipJarProduct.allCases.count)
        #expect(TipJarProduct.contains(identifiers[0], bundleIdentifier: bundleIdentifier))
        #expect(
            !TipJarProduct.contains("at.oncloud.encryptedmemories.other.tip.s", bundleIdentifier: bundleIdentifier))
    }
}
