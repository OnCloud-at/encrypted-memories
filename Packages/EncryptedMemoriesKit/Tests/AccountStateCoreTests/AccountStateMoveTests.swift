import Foundation
import PhotosCore
import Testing

@testable import AccountStateCore

@Suite("Account state move marker")
struct AccountStateMoveTests {
    @Test func moveMarkerRoundTripsAndBlocksEveryLaterChange() throws {
        var document = try documentHiding([photoA])
        try document.markMoved(to: "location-2", at: stateDate(2_000), deviceID: "mac", nonce: 3)

        let decoded = try AccountStateDocument(data: document.encoded())

        #expect(decoded == document)
        #expect(decoded.movedTo == "location-2")
        #expect(decoded.isUsable)
        var changed = decoded
        #expect(throws: AccountStateMovedError(location: "location-2")) {
            try changed.setHidden(photoB, true, at: stateDate(3_000), deviceID: "mac")
        }
        #expect(throws: AccountStateMovedError(location: "location-2")) {
            try changed.setValue(false, for: .sharedLibraryEnabled, at: stateDate(3_000), deviceID: "mac")
        }
    }

    @Test func documentsWithoutMarkerKeepTheirBytes() throws {
        let document = try documentHiding([photoA])
        let text = String(decoding: try document.encoded(), as: UTF8.self)
        #expect(!text.contains("movedTo"))
    }

    @Test func markerSurvivesMergeInEveryOrder() throws {
        var moved = try documentHiding([photoA])
        try moved.markMoved(to: "location-2", at: stateDate(2_000), deviceID: "mac", nonce: 3)
        let other = try documentHiding([photoB], device: "iphone")

        let left = try #require(AccountStateDocument.merged(moved, other))
        let right = try #require(AccountStateDocument.merged(other, moved))

        #expect(left == right)
        #expect(left.movedTo == "location-2")
        #expect(left.hiddenPhotos == [photoA, photoB])
    }

    @Test func laterMarkerWinsAndEqualStampsPickTheSameLocation() throws {
        var first = AccountStateDocument()
        try first.markMoved(to: "location-a", at: stateDate(2_000), deviceID: "mac", nonce: 1)
        var later = AccountStateDocument()
        try later.markMoved(to: "location-b", at: stateDate(3_000), deviceID: "mac", nonce: 1)
        #expect(AccountStateDocument.merged(first, later)?.movedTo == "location-b")
        #expect(AccountStateDocument.merged(later, first)?.movedTo == "location-b")

        var tieA = AccountStateDocument()
        try tieA.markMoved(to: "location-a", at: stateDate(2_000), deviceID: "mac", nonce: 1)
        var tieB = AccountStateDocument()
        try tieB.markMoved(to: "location-b", at: stateDate(2_000), deviceID: "mac", nonce: 1)
        #expect(AccountStateDocument.merged(tieA, tieB) == AccountStateDocument.merged(tieB, tieA))
    }

    @Test func unreadableMarkerIsDamageNotAnUnknownField() throws {
        for raw in [
            #"{"format":1,"movedTo":"location"}"#,
            #"{"format":1,"movedTo":{"location":"","time":1,"device":"mac","nonce":"000000000000000a"}}"#,
            #"{"format":1,"movedTo":{"location":"x","time":1,"device":"mac"}}"#,
        ] {
            let document = try AccountStateDocument(data: Data(raw.utf8))
            #expect(document.isDamaged)
            #expect(!document.isUsable)
            #expect(document.extraFields["movedTo"] == nil)
            #expect(document.movedTo == nil)
        }
    }

    @Test func markerFromANewerBuildKeepsItsExtraFields() throws {
        let raw =
            #"{"format":1,"movedTo":{"device":"mac","location":"x","nonce":"000000000000000a","time":1,"via":"v2"}}"#
        let document = try AccountStateDocument(data: Data(raw.utf8))
        #expect(document.movedTo == "x")
        #expect(String(decoding: try document.encoded(), as: UTF8.self).contains(#""via":"v2""#))
    }

    @Test func invalidLocationsAreRejected() throws {
        var document = AccountStateDocument()
        #expect(throws: AccountStateInvalidChangeError.self) {
            try document.markMoved(to: "", at: stateDate(1), deviceID: "mac")
        }
        #expect(throws: AccountStateInvalidChangeError.self) {
            try document.markMoved(to: String(repeating: "x", count: 1_025), at: stateDate(1), deviceID: "mac")
        }
        #expect(document.movedTo == nil)
    }
}
