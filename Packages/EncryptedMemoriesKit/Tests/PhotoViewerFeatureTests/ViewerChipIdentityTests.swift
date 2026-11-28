import Testing

@testable import PhotoViewerCore

/// The album chips of the viewer's info panels on macOS, iOS and iPadOS identify their titles for SwiftUI. Two albums
/// can carry the same title, so each chip is identified by its title and by how many equal titles precede it. The
/// rendering keeps every title, including a repeated one.
@Suite struct ViewerChipIdentityTests {
    @Test func uniqueTitlesKeepTheirOrderAndFirstOccurrence() {
        let chips = ViewerChipIdentity.forTitles(["Beach", "City", "Mountains"])
        #expect(chips.map(\.title) == ["Beach", "City", "Mountains"])
        #expect(chips.map(\.id.occurrence) == [0, 0, 0])
    }

    @Test func equalTitlesGetTheirOwnIdentities() {
        let chips = ViewerChipIdentity.forTitles(["Trips", "Trips", "Other", "Trips"])
        #expect(chips.map(\.title) == ["Trips", "Trips", "Other", "Trips"])
        #expect(chips.map(\.id.occurrence) == [0, 1, 0, 2])
        #expect(Set(chips.map(\.id)).count == 4, "every identity is unique")
    }

    /// A title that looks like the identity of a repeated title still gets its own identity.
    @Test func aTitleThatSpellsARepeatedIdentityStaysUnique() {
        let titles = ["Trips", "Trips", "Trips#1", "Trips 1", "Trips"]
        let chips = ViewerChipIdentity.forTitles(titles)
        #expect(chips.map(\.title) == titles)
        #expect(Set(chips.map(\.id)).count == titles.count, "every identity is unique")
    }

    @Test func theEmptyListHasNoIdentities() {
        #expect(ViewerChipIdentity.forTitles([]).isEmpty)
    }
}
