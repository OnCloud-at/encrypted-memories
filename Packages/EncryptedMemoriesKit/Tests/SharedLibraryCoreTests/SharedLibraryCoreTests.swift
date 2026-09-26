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
        try journal.record(.hidden(photo, isHidden: true), at: date(1))
        try journal.record(.personal(photo, isPersonal: false), at: date(2))
        try journal.record(.settings(SharedLibrarySettings(isEnabled: true, scope: .since(date(50)))), at: date(3))
        try journal.record(.settings(.off), at: date(4))
        try journal.record(.shardCreated(index: 2, album: album), at: date(5))
        try journal.record(.shardRetired(album: album), at: date(6))

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
            try Issue.record("the unknown change must stay unrecognized")
            return
        }
        try journal.record(.personal(photo, isPersonal: true), at: date(3))
        let rewritten = try roundTrip(journal.compacted())

        #expect(rewritten.entries.contains { $0.change == journal.entries[1].change }, "kept verbatim")
        let state = SharedLibraryState.merged([rewritten])
        #expect(state.visibility(of: photo) == .hidden)
        let onlyUnknown = SharedLibraryJournal(deviceID: "mac", entries: [journal.entries[1]])
        #expect(SharedLibraryState.merged([onlyUnknown]) == SharedLibraryState(), "never applied")
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

    @Test func theLatestChangeWinsAcrossDevices() throws {
        var mac = SharedLibraryJournal(deviceID: "mac")
        var phone = SharedLibraryJournal(deviceID: "phone")
        try mac.record(.hidden(photo, isHidden: true), at: date(10))
        try phone.record(.hidden(photo, isHidden: false), at: date(20))
        #expect(SharedLibraryState.merged([mac, phone]).visibility(of: photo) == .normal)
        #expect(SharedLibraryState.merged([phone, mac]).visibility(of: photo) == .normal, "order of journals")

        try mac.record(.hidden(photo, isHidden: true), at: date(30))
        #expect(SharedLibraryState.merged([mac, phone]).visibility(of: photo) == .hidden)
    }

    @Test func equalTimesResolveTheSameWayOnEveryDevice() throws {
        var mac = SharedLibraryJournal(deviceID: "mac")
        var phone = SharedLibraryJournal(deviceID: "phone")
        try mac.record(.personal(photo, isPersonal: true), at: date(10))
        try phone.record(.personal(photo, isPersonal: false), at: date(10))
        let merged = SharedLibraryState.merged([mac, phone])
        #expect(merged == SharedLibraryState.merged([phone, mac]))
        #expect(merged.visibility(of: photo) == .normal, "the higher device ID wins a tie")
    }

    @Test func showingAHiddenPhotoAgainRestoresNurFuerMich() throws {
        var journal = SharedLibraryJournal(deviceID: "mac")
        try journal.record(.personal(photo, isPersonal: true), at: date(1))
        try journal.record(.hidden(photo, isHidden: true), at: date(2))
        #expect(SharedLibraryState.merged([journal]).visibility(of: photo) == .hidden)

        try journal.record(.hidden(photo, isHidden: false), at: date(3))
        #expect(SharedLibraryState.merged([journal]).visibility(of: photo) == .personal)
    }

    @Test func aRetiredShardLeavesTheStateAndShardsStayInIndexOrder() throws {
        let second = AlbumNodeIdentifier(volumeID: "volume", nodeID: "second")
        var journal = SharedLibraryJournal(deviceID: "mac")
        try journal.record(.shardCreated(index: 2, album: second), at: date(1))
        try journal.record(.shardCreated(index: 1, album: album), at: date(2))
        #expect(SharedLibraryState.merged([journal]).shards.map(\.index) == [1, 2])

        try journal.record(.shardRetired(album: second), at: date(3))
        #expect(SharedLibraryState.merged([journal]).shards == [ShardRecord(index: 1, album: album)])
    }

    @Test func compactionKeepsTheMergedStateAndDropsSupersededChanges() throws {
        var journal = SharedLibraryJournal(deviceID: "mac")
        for second in 0..<300 {
            try journal.record(.hidden(photo, isHidden: second.isMultiple(of: 2)), at: date(TimeInterval(second)))
        }
        try journal.record(.settings(SharedLibrarySettings(isEnabled: true, scope: .everything)), at: date(400))
        #expect(journal.needsCompaction)

        let compacted = journal.compacted()
        #expect(compacted.entries.count == 2)
        #expect(SharedLibraryState.merged([compacted]) == SharedLibraryState.merged([journal]))
        #expect(!compacted.needsCompaction)
    }
}

@Suite("Shared library journal robustness")
struct SharedLibraryJournalRobustnessTests {
    private let photo = PhotoUID(volumeID: "volume", nodeID: "photo")

    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    private func journal(_ json: String) throws -> SharedLibraryJournal {
        try JSONDecoder().decode(SharedLibraryJournal.self, from: Data(json.utf8))
    }

    @Test func anOutOfRangeShardIndexIsIgnoredInsteadOfCrashing() throws {
        let decoded = try journal(
            """
            {"format":1,"device":"mac","entries":[
              {"device":"mac","seq":1,"time":1,"change":{"type":"shardCreated","index":9223372036854775808,
               "album":{"volumeID":"v","nodeID":"a"}}},
              {"device":"mac","seq":2,"time":2,"change":{"type":"shardCreated","index":1.5,
               "album":{"volumeID":"v","nodeID":"b"}}}
            ]}
            """)
        #expect(SharedLibraryState.merged([decoded]).shards.isEmpty)
    }

    @Test func aNumberWhereAFlagBelongsIsIgnored() throws {
        let decoded = try journal(
            """
            {"format":1,"device":"mac","entries":[
              {"device":"mac","seq":1,"time":1,"change":{"type":"hidden",
               "photo":{"volumeID":"volume","nodeID":"photo"},"value":1}}
            ]}
            """)
        #expect(SharedLibraryState.merged([decoded]).hidden.isEmpty)
    }

    @Test func aDamagedEntryHidesOnlyItselfAndSurvivesARewrite() throws {
        var decoded = try journal(
            """
            {"format":1,"device":"mac","entries":[
              {"device":"mac","seq":-1,"time":1,"change":{"type":"hidden",
               "photo":{"volumeID":"volume","nodeID":"other"},"value":true}},
              {"device":"mac","seq":2,"time":2,"change":{"type":"personal",
               "photo":{"volumeID":"volume","nodeID":"photo"},"value":true}}
            ]}
            """)
        #expect(decoded.unreadableEntries.count == 1)
        #expect(SharedLibraryState.merged([decoded]).visibility(of: photo) == .personal)

        try decoded.record(.hidden(photo, isHidden: true), at: date(3))
        let rewritten = try JSONDecoder().decode(
            SharedLibraryJournal.self, from: JSONEncoder().encode(decoded.compacted()))
        #expect(rewritten.unreadableEntries == decoded.unreadableEntries)
        #expect(rewritten.entries.map(\.sequence) == [2, 3])
    }

    @Test func aNewerJournalCannotBeChangedOrWrittenButDoesNotCrash() throws {
        var newer = try journal(#"{"format":2,"device":"mac","entries":[]}"#)
        #expect(throws: SharedLibraryJournalReadOnlyError(format: 2)) {
            try newer.record(.hidden(photo, isHidden: true), at: date(1))
        }
        #expect(throws: SharedLibraryJournalReadOnlyError.self) { try JSONEncoder().encode(newer) }
        #expect(newer.compacted() == newer)
    }

    @Test func twoJournalsOfOneDeviceMergeTheSameWayInEveryOrder() {
        let tie = date(10)
        let a = SharedLibraryJournal(
            deviceID: "mac",
            entries: [
                SharedLibraryJournalEntry(
                    deviceID: "mac", sequence: 1, recordedAt: tie, change: .hidden(photo, isHidden: true))
            ])
        let b = SharedLibraryJournal(
            deviceID: "mac",
            entries: [
                SharedLibraryJournalEntry(
                    deviceID: "mac", sequence: 1, recordedAt: tie, change: .hidden(photo, isHidden: false))
            ])
        #expect(SharedLibraryState.merged([a, b]) == SharedLibraryState.merged([b, a]))
    }

    @Test func compactingOneDeviceKeepsTheStateThatAllDevicesMerge() throws {
        var mac = SharedLibraryJournal(deviceID: "mac")
        var phone = SharedLibraryJournal(deviceID: "phone")
        try mac.record(.hidden(photo, isHidden: true), at: date(1))
        try phone.record(.hidden(photo, isHidden: true), at: date(2))
        try mac.record(.hidden(photo, isHidden: false), at: date(3))
        try mac.record(.hidden(photo, isHidden: false), at: date(4))

        let before = SharedLibraryState.merged([mac, phone])
        #expect(before.visibility(of: photo) == .normal, "the later false must beat the other device's true")
        #expect(SharedLibraryState.merged([mac.compacted(), phone]) == before)
        #expect(SharedLibraryState.merged([mac.compacted(), phone.compacted()]) == before)
    }

    @Test func largeNumbersInAChangeFromANewerBuildKeepEveryDigit() throws {
        let decoded = try journal(
            """
            {"format":1,"device":"mac","entries":[
              {"device":"mac","seq":1,"time":1,"change":{"type":"futureThing","id":9223372036854775807}}
            ]}
            """)
        let text = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(text.contains("9223372036854775807"))
    }

    @Test func theSequenceKeepsGrowingAfterCompactionWithAClockThatWentBack() throws {
        var mac = SharedLibraryJournal(deviceID: "mac")
        try mac.record(.hidden(photo, isHidden: true), at: date(100))
        try mac.record(.hidden(photo, isHidden: false), at: date(50))
        var compacted = mac.compacted()
        #expect(compacted.entries.map(\.sequence) == [1], "the later time wins even with the lower sequence")

        try compacted.record(.personal(photo, isPersonal: true), at: date(60))
        #expect(compacted.entries.last?.sequence == 3)
        let reread = try JSONDecoder().decode(SharedLibraryJournal.self, from: JSONEncoder().encode(compacted))
        #expect(reread.lastSequence == 3)
    }

    @Test func aShardNameInAnotherUnicodeFormStillMatches() {
        let decomposed = ShardNaming.name(forIndex: 3).decomposedStringWithCanonicalMapping
        #expect(ShardNaming.index(ofName: decomposed) == 3)
    }

    @Test func aStartDateSurvivesTheJournalExactly() throws {
        var mac = SharedLibraryJournal(deviceID: "mac")
        let start = Date(timeIntervalSince1970: 1_790_000_000.123_456)
        try mac.record(.settings(SharedLibrarySettings(isEnabled: true, scope: .since(start))), at: date(1))
        let reread = try JSONDecoder().decode(SharedLibraryJournal.self, from: JSONEncoder().encode(mac))
        #expect(SharedLibraryState.merged([reread]).settings.scope == .since(start))
    }
}

@Suite("Shared library journal limits")
struct SharedLibraryJournalLimitTests {
    private let photo = PhotoUID(volumeID: "volume", nodeID: "photo")

    private func journal(_ json: String) throws -> SharedLibraryJournal {
        try JSONDecoder().decode(SharedLibraryJournal.self, from: Data(json.utf8))
    }

    @Test func aHugeNumberInOneEntryLeavesTheOtherEntriesReadable() throws {
        let decoded = try journal(
            """
            {"format":1,"device":"mac","entries":[
              {"device":"mac","seq":1,"time":1,"change":{"type":"futureThing","size":1e400}},
              {"device":"mac","seq":2,"time":2,"change":{"type":"hidden",
               "photo":{"volumeID":"volume","nodeID":"photo"},"value":true}}
            ]}
            """)
        #expect(SharedLibraryState.merged([decoded]).visibility(of: photo) == .hidden)
    }

    @Test func aUsedUpSequenceRefusesTheChangeInsteadOfCrashing() throws {
        var full = try journal(#"{"format":1,"device":"mac","entries":[],"last":18446744073709551615}"#)
        #expect(throws: SharedLibraryJournalInvalidChangeError()) {
            try full.record(.hidden(photo, isHidden: true), at: Date(timeIntervalSince1970: 1))
        }
        #expect(full.entries.isEmpty)
    }

    @Test func aDateThatIsNotFiniteIsRefusedAndNeverCrashesAWrite() throws {
        var mac = SharedLibraryJournal(deviceID: "mac")
        let infinite = Date(timeIntervalSince1970: .infinity)
        #expect(throws: SharedLibraryJournalInvalidChangeError()) {
            try mac.record(.settings(SharedLibrarySettings(isEnabled: true, scope: .since(infinite))), at: Date())
        }
        #expect(throws: SharedLibraryJournalInvalidChangeError()) {
            try mac.record(.hidden(photo, isHidden: true), at: infinite)
        }
        let bypassed = SharedLibraryJournal(
            deviceID: "mac",
            entries: [
                SharedLibraryJournalEntry(
                    deviceID: "mac", sequence: 1, recordedAt: Date(timeIntervalSince1970: 1),
                    change: .settings(SharedLibrarySettings(isEnabled: true, scope: .since(infinite))))
            ])
        _ = try? JSONEncoder().encode(bypassed)
    }

    @Test func aShardIndexIsCheckedFromItsExactDigits() throws {
        let decoded = try journal(
            """
            {"format":1,"device":"mac","entries":[
              {"device":"mac","seq":1,"time":1,"change":{"type":"shardCreated","index":1.0000000000000001,
               "album":{"volumeID":"v","nodeID":"a"}}},
              {"device":"mac","seq":2,"time":2,"change":{"type":"shardCreated","index":9007199254740993,
               "album":{"volumeID":"v","nodeID":"b"}}}
            ]}
            """)
        #expect(SharedLibraryState.merged([decoded]).shards.map(\.index) == [9_007_199_254_740_993])
    }

    @Test func aSequenceInAnUnreadableEntryIsNeverUsedAgain() throws {
        var decoded = try journal(
            """
            {"format":1,"device":"mac","entries":[
              {"device":"mac","seq":1,"time":1,"change":{"type":"hidden",
               "photo":{"volumeID":"volume","nodeID":"photo"},"value":true}},
              {"device":"mac","seq":2,"change":{"type":"hidden",
               "photo":{"volumeID":"volume","nodeID":"photo"},"value":false}}
            ]}
            """)
        #expect(decoded.lastSequence == 2)
        try decoded.record(.personal(photo, isPersonal: true), at: Date(timeIntervalSince1970: 3))
        #expect(decoded.entries.last?.sequence == 3)
    }

    @Test func shardsWithTheSameIndexAndNodeSortByVolumeToo() throws {
        var a = SharedLibraryJournal(deviceID: "a")
        var b = SharedLibraryJournal(deviceID: "b")
        try a.record(.shardCreated(index: 1, album: AlbumNodeIdentifier(volumeID: "v2", nodeID: "n")), at: .init())
        try b.record(.shardCreated(index: 1, album: AlbumNodeIdentifier(volumeID: "v1", nodeID: "n")), at: .init())
        let merged = SharedLibraryState.merged([a, b])
        #expect(merged == SharedLibraryState.merged([b, a]))
        #expect(merged.shards.map(\.album.volumeID) == ["v1", "v2"])
    }
}

@Suite("Shared library scope safety")
struct SharedLibraryScopeSafetyTests {
    private func journal(_ json: String) throws -> SharedLibraryJournal {
        try JSONDecoder().decode(SharedLibraryJournal.self, from: Data(json.utf8))
    }

    private func settingsChange(since: String) -> String {
        """
        {"format":1,"device":"mac","entries":[
          {"device":"mac","seq":1,"time":1,"change":{"type":"settings","enabled":true,"since":1000}},
          {"device":"mac","seq":2,"time":2,"change":{"type":"settings","enabled":true,"since":\(since)}}
        ]}
        """
    }

    @Test(arguments: ["null", "1e400", "\"soon\""])
    func anUnreadableStartDateNeverWidensWhatIsShared(since: String) throws {
        let decoded = try journal(settingsChange(since: since))
        #expect(
            SharedLibraryState.merged([decoded]).settings.scope == .since(Date(timeIntervalSince1970: 1000)),
            "the damaged change is ignored; the earlier start date stays")
    }

    @Test func aStartDateBeyondWhatTheJournalCanHoldIsRefused() throws {
        var mac = SharedLibraryJournal(deviceID: "mac")
        let farFuture = Date(timeIntervalSince1970: 1e200)
        let change = SharedLibraryChange.settings(SharedLibrarySettings(isEnabled: true, scope: .since(farFuture)))
        #expect(throws: SharedLibraryJournalInvalidChangeError()) { try mac.record(change, at: Date()) }

        let bypassed = SharedLibraryJournal(
            deviceID: "mac",
            entries: [
                SharedLibraryJournalEntry(
                    deviceID: "mac", sequence: 1, recordedAt: Date(timeIntervalSince1970: 1), change: change)
            ])
        #expect(throws: (any Error).self) { try JSONEncoder().encode(bypassed) }
    }

    @Test func aDamagedCounterKeepsTheEntriesButMakesTheJournalReadOnly() throws {
        var damaged = try journal(
            """
            {"format":1,"device":"mac","last":"100","entries":[
              {"device":"mac","seq":1,"time":1,"change":{"type":"hidden",
               "photo":{"volumeID":"volume","nodeID":"photo"},"value":true}}
            ]}
            """)
        #expect(!damaged.isAppendable)
        #expect(SharedLibraryState.merged([damaged]).hidden.count == 1, "its entries still count")
        #expect(throws: SharedLibraryJournalDamagedError()) {
            try damaged.record(
                .hidden(PhotoUID(volumeID: "volume", nodeID: "photo"), isHidden: false), at: Date())
        }
        #expect(throws: SharedLibraryJournalDamagedError.self) { try JSONEncoder().encode(damaged) }
        #expect(damaged.compacted() == damaged)
    }
}

@Suite("Shared library date and counter edges")
struct SharedLibraryEdgeTests {
    @Test(arguments: [-86_400.5, 0.000_001, 1_790_000_000.987_654, 4_102_444_800.25, 1e15, -1e-7])
    func realisticStartDatesRoundTripExactly(seconds: Double) throws {
        var mac = SharedLibraryJournal(deviceID: "mac")
        let start = Date(timeIntervalSince1970: seconds)
        try mac.record(.settings(SharedLibrarySettings(isEnabled: true, scope: .since(start))), at: Date())
        let reread = try JSONDecoder().decode(SharedLibraryJournal.self, from: JSONEncoder().encode(mac))
        #expect(SharedLibraryState.merged([reread]).settings.scope == .since(start))
    }

    @Test(arguments: ["-1", "1.5", "null", "true", "[1]"])
    func everyDamagedCounterMakesTheJournalReadOnly(last: String) throws {
        let json = #"{"format":1,"device":"mac","entries":[],"last":\#(last)}"#
        let decoded = try JSONDecoder().decode(SharedLibraryJournal.self, from: Data(json.utf8))
        #expect(!decoded.isAppendable)
    }
}
