import AlbumCore
import Foundation
import PhotosCore
import Testing

@testable import SharedLibraryCore

@Suite("Photo visibility")
struct PhotoVisibilityTests {
    @Test func hiddenWinsOverPersonalAndPersonalWinsOverSharing() {
        #expect(PhotoVisibility(isHidden: true, isPersonal: true) == .hidden)
        #expect(PhotoVisibility(isHidden: true, isPersonal: false) == .hidden)
        #expect(PhotoVisibility(isHidden: false, isPersonal: true) == .personal)
        #expect(PhotoVisibility(isHidden: false, isPersonal: false) == .normal)
    }

    @Test func onlyNormalPhotosAreSharedAndOnlyHiddenPhotosLeaveTheLibrary() {
        #expect(PhotoVisibility.normal.isShareable && PhotoVisibility.normal.isInLibrary)
        #expect(!PhotoVisibility.personal.isShareable && PhotoVisibility.personal.isInLibrary)
        #expect(!PhotoVisibility.hidden.isShareable && !PhotoVisibility.hidden.isInLibrary)
    }
}

@Suite("Sharing settings")
struct SharedLibrarySettingsTests {
    @Test func aStartDateIncludesPhotosFromThatMomentOn() {
        let start = Date(timeIntervalSince1970: 1_000)
        let settings = SharedLibrarySettings(isEnabled: true, scope: .since(start))
        #expect(settings.includes(captureTime: start))
        #expect(!settings.includes(captureTime: start.addingTimeInterval(-1)))
        #expect(SharedLibrarySettings(isEnabled: true, scope: .everything).includes(captureTime: .distantPast))
    }
}

@Suite("Shard albums")
struct ShardRulesTests {
    @Test func aShardNameRoundTripsItsIndex() {
        #expect(ShardNaming.index(ofName: ShardNaming.name(forIndex: 1)) == 1)
        #expect(ShardNaming.index(ofName: ShardNaming.name(forIndex: 42)) == 42)
    }

    @Test func onlyExactShardNamesAreRecognized() {
        for name in [
            ShardNaming.prefix, "\(ShardNaming.prefix) 0", "\(ShardNaming.prefix) 01", "\(ShardNaming.prefix) 1a",
            "\(ShardNaming.prefix)  1", "\(ShardNaming.prefix) -1", "Vacation 1", "\(ShardNaming.prefix) ١",
        ] {
            #expect(ShardNaming.index(ofName: name) == nil, "\(name)")
        }
    }

    @Test func fillingStopsAtTheTargetAndCountsEveryFileOfAGroup() {
        let policy = ShardCapacityPolicy(fillTarget: 10, hardLimit: 12, maximumAlbums: 3)
        #expect(policy.accepts(groupSize: 2, into: 8))
        #expect(!policy.accepts(groupSize: 2, into: 9), "a Live Photo's video counts too")
        #expect(policy.accepts(groupSize: 0, into: 9), "every group counts at least once")
        #expect(policy.canCreateAlbum(existingAlbumCount: 2))
        #expect(!policy.canCreateAlbum(existingAlbumCount: 3))
    }

    @Test func protonLimitsLeaveAMargin() {
        #expect(ShardCapacityPolicy.proton.fillTarget < ShardCapacityPolicy.proton.hardLimit)
        #expect(ShardCapacityPolicy.proton.hardLimit == 10_000)
        #expect(ShardCapacityPolicy.proton.maximumAlbums == 500)
    }
}

@Suite("Shared library journal")
struct SharedLibraryJournalTests {
    private let photo = PhotoUID(volumeID: "volume", nodeID: "photo")
    private let album = AlbumNodeIdentifier(volumeID: "volume", nodeID: "album")

    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    private func roundTrip(_ journal: SharedLibraryJournal) throws -> SharedLibraryJournal {
        try JSONDecoder().decode(SharedLibraryJournal.self, from: JSONEncoder().encode(journal))
    }

    @Test func everyChangeRoundTrips() throws {
        var journal = SharedLibraryJournal(deviceID: "mac")
        journal.record(.hidden(photo, true), at: date(1))
        journal.record(.personal(photo, false), at: date(2))
        journal.record(.settings(SharedLibrarySettings(isEnabled: true, scope: .since(date(50)))), at: date(3))
        journal.record(.settings(.off), at: date(4))
        journal.record(.shardCreated(index: 2, album: album), at: date(5))
        journal.record(.shardRetired(album: album), at: date(6))

        #expect(try roundTrip(journal) == journal)
        #expect(journal.entries.map(\.sequence) == [1, 2, 3, 4, 5, 6])
    }

    @Test func aChangeFromANewerBuildSurvivesARewriteAndIsNeverApplied() throws {
        let json = """
            {"format":1,"device":"mac","entries":[
              {"device":"mac","seq":1,"time":1,"change":{"type":"hidden","photo":{"volumeID":"volume","nodeID":"photo"},"value":true}},
              {"device":"mac","seq":2,"time":2,"change":{"type":"futureThing","weight":3,"list":[true,null,"x"]}}
            ]}
            """
        var journal = try JSONDecoder().decode(SharedLibraryJournal.self, from: Data(json.utf8))
        guard case .unrecognized = journal.entries[1].change else {
            Issue.record("the unknown change must stay unrecognized")
            return
        }
        journal.record(.personal(photo, true), at: date(3))
        let rewritten = try roundTrip(journal.compacted())

        #expect(rewritten.entries.contains { $0.change == journal.entries[1].change }, "kept verbatim")
        let state = SharedLibraryState.merged([rewritten])
        #expect(state.visibility(of: photo) == .hidden)
    }

    @Test func aDamagedKnownChangeIsIgnoredInsteadOfBreakingTheJournal() throws {
        let json = """
            {"format":1,"device":"mac","entries":[
              {"device":"mac","seq":1,"time":1,"change":{"type":"hidden","photo":{"volumeID":"volume"},"value":true}}
            ]}
            """
        let journal = try JSONDecoder().decode(SharedLibraryJournal.self, from: Data(json.utf8))
        #expect(SharedLibraryState.merged([journal]).hidden.isEmpty)
    }

    @Test func aJournalInANewerFormatIsReadOnlyAndDoesNotCount() throws {
        let json = """
            {"format":2,"device":"iphone","entries":{"a":"new layout"}}
            """
        let journal = try JSONDecoder().decode(SharedLibraryJournal.self, from: Data(json.utf8))
        #expect(!journal.isSupported)
        #expect(SharedLibraryState.merged([journal]) == SharedLibraryState())
    }

    @Test func theLatestChangeWinsAcrossDevices() {
        var mac = SharedLibraryJournal(deviceID: "mac")
        var phone = SharedLibraryJournal(deviceID: "phone")
        mac.record(.hidden(photo, true), at: date(10))
        phone.record(.hidden(photo, false), at: date(20))
        #expect(SharedLibraryState.merged([mac, phone]).visibility(of: photo) == .normal)
        #expect(SharedLibraryState.merged([phone, mac]).visibility(of: photo) == .normal, "order of journals")

        mac.record(.hidden(photo, true), at: date(30))
        #expect(SharedLibraryState.merged([mac, phone]).visibility(of: photo) == .hidden)
    }

    @Test func equalTimesResolveTheSameWayOnEveryDevice() {
        var mac = SharedLibraryJournal(deviceID: "mac")
        var phone = SharedLibraryJournal(deviceID: "phone")
        mac.record(.personal(photo, true), at: date(10))
        phone.record(.personal(photo, false), at: date(10))
        let merged = SharedLibraryState.merged([mac, phone])
        #expect(merged == SharedLibraryState.merged([phone, mac]))
        #expect(merged.visibility(of: photo) == .normal, "the higher device ID wins a tie")
    }

    @Test func showingAHiddenPhotoAgainRestoresNurFuerMich() {
        var journal = SharedLibraryJournal(deviceID: "mac")
        journal.record(.personal(photo, true), at: date(1))
        journal.record(.hidden(photo, true), at: date(2))
        #expect(SharedLibraryState.merged([journal]).visibility(of: photo) == .hidden)

        journal.record(.hidden(photo, false), at: date(3))
        #expect(SharedLibraryState.merged([journal]).visibility(of: photo) == .personal)
    }

    @Test func aRetiredShardLeavesTheStateAndShardsStayInIndexOrder() {
        let second = AlbumNodeIdentifier(volumeID: "volume", nodeID: "second")
        var journal = SharedLibraryJournal(deviceID: "mac")
        journal.record(.shardCreated(index: 2, album: second), at: date(1))
        journal.record(.shardCreated(index: 1, album: album), at: date(2))
        #expect(SharedLibraryState.merged([journal]).shards.map(\.index) == [1, 2])

        journal.record(.shardRetired(album: second), at: date(3))
        #expect(SharedLibraryState.merged([journal]).shards == [ShardRecord(index: 1, album: album)])
    }

    @Test func compactionKeepsTheMergedStateAndDropsSupersededChanges() {
        var journal = SharedLibraryJournal(deviceID: "mac")
        for second in 0..<300 {
            journal.record(.hidden(photo, second.isMultiple(of: 2)), at: date(TimeInterval(second)))
        }
        journal.record(.settings(SharedLibrarySettings(isEnabled: true, scope: .everything)), at: date(400))
        #expect(journal.needsCompaction)

        let compacted = journal.compacted()
        #expect(compacted.entries.count == 2)
        #expect(SharedLibraryState.merged([compacted]) == SharedLibraryState.merged([journal]))
        #expect(!compacted.needsCompaction)
    }
}
