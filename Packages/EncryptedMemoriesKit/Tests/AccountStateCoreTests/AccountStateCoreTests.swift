import Foundation
import PhotosCore
import Testing

@testable import AccountStateCore

private let photo = PhotoUID(volumeID: "volume", nodeID: "photo")
private let other = PhotoUID(volumeID: "volume", nodeID: "other")

private func date(_ milliseconds: Int64) -> Date {
    Date(timeIntervalSince1970: Double(milliseconds) / 1000)
}

private func document(_ json: String) throws -> AccountStateDocument {
    try AccountStateDocument(data: Data(json.utf8))
}

private func text(_ document: AccountStateDocument) throws -> String {
    String(decoding: try document.encoded(), as: UTF8.self)
}

private func value(_ json: String) -> AccountStateJSONValue? {
    AccountStateJSONValue(json: Data(json.utf8))
}

/// A readable hidden entry with a fixed nonce.
private func hiddenEntry(
    _ node: String, _ value: Bool, time: Int64, device: String = "mac", extra: String = ""
) -> String {
    #"{"volumeID":"volume","nodeID":"\#(node)","value":\#(value),"time":\#(time),"device":"\#(device)","nonce":"000000000000000a"\#(extra)}"#
}

@Suite("Account state document")
struct AccountStateDocumentTests {
    @Test func hiddenPhotosAndSettingsRoundTripExactly() throws {
        var state = AccountStateDocument()
        try state.setHidden(photo, true, at: date(1_790_000_000_123), deviceID: "mac", nonce: 1)
        try state.setHidden(other, false, at: date(1_790_000_000_124), deviceID: "iphone", nonce: .max)
        try state.setValue(true, for: .sharedLibraryEnabled, at: date(1_790_000_000_125), deviceID: "mac", nonce: 3)

        let decoded = try AccountStateDocument(data: state.encoded())

        #expect(decoded == state)
        #expect(decoded.hiddenPhotos == [photo])
        #expect(decoded.value(for: .sharedLibraryEnabled) == true)
        #expect(
            decoded.hiddenRegisters[photo]?.stamp
                == AccountStateStamp(time: 1_790_000_000_123, deviceID: "mac", nonce: 1))
    }

    @Test func equalDocumentsGiveEqualBytes() throws {
        var first = AccountStateDocument()
        try first.setHidden(photo, true, at: date(10), deviceID: "mac", nonce: 1)
        try first.setHidden(other, true, at: date(20), deviceID: "mac", nonce: 2)
        var second = AccountStateDocument()
        try second.setHidden(other, true, at: date(20), deviceID: "mac", nonce: 2)
        try second.setHidden(photo, true, at: date(10), deviceID: "mac", nonce: 1)

        #expect(try first.encoded() == second.encoded())
    }

    @Test func aMissingSettingIsNil() {
        #expect(AccountStateDocument().value(for: .sharedLibraryEnabled) == nil)
    }

    @Test func aSettingOfAnotherTypeReadsAsMissing() throws {
        let state = try document(
            #"{"format":1,"settings":{"sharedLibrary.enabled":{"value":1,"time":1,"device":"m","nonce":"0000000000000001"}}}"#
        )
        #expect(state.isUsable)
        #expect(state.value(for: .sharedLibraryEnabled) == nil)
    }

    @Test func showingAPhotoAgainKeepsItsRegisterSoAnOlderCopyCannotHideItAgain() throws {
        var older = AccountStateDocument()
        try older.setHidden(photo, true, at: date(10), deviceID: "iphone")
        var newer = older
        try newer.setHidden(photo, false, at: date(20), deviceID: "mac")

        let merged = try #require(AccountStateDocument.merged(older, newer))

        #expect(!merged.isHidden(photo))
        #expect(merged.hiddenRegisters[photo]?.value == false)
    }

    @Test func aChangeSupersedesWhatTheDeviceSawEvenWithAClockThatIsBehind() throws {
        var state = AccountStateDocument()
        try state.setHidden(photo, true, at: date(5_000), deviceID: "mac")
        // The iPhone's clock is behind; showing the photo again must still win.
        try state.setHidden(photo, false, at: date(1_000), deviceID: "iphone", nonce: 0)

        #expect(!state.isHidden(photo))
        #expect(state.hiddenRegisters[photo]?.stamp == AccountStateStamp(time: 5_001, deviceID: "iphone", nonce: 0))
    }
}

@Suite("Account state merge")
struct AccountStateMergeTests {
    private func samples() throws -> [AccountStateDocument] {
        var a = AccountStateDocument()
        try a.setHidden(photo, true, at: date(10), deviceID: "mac", nonce: 1)
        try a.setValue(true, for: .sharedLibraryEnabled, at: date(30), deviceID: "mac", nonce: 2)
        var b = AccountStateDocument()
        try b.setHidden(photo, false, at: date(20), deviceID: "iphone", nonce: 3)
        try b.setHidden(other, true, at: date(5), deviceID: "iphone", nonce: 4)
        var c = AccountStateDocument()
        try c.setValue(false, for: .sharedLibraryEnabled, at: date(40), deviceID: "ipad", nonce: 5)
        try c.setHidden(other, false, at: date(5), deviceID: "ipad", nonce: 6)
        return [a, b, c]
    }

    @Test func theResultIsTheSameInAnyOrderAndMergingAgainChangesNothing() throws {
        let documents = try samples()
        let (a, b, c) = (documents[0], documents[1], documents[2])
        let ab = try #require(AccountStateDocument.merged(a, b))
        let ba = try #require(AccountStateDocument.merged(b, a))
        let abc = try #require(AccountStateDocument.merged(ab, c))
        let bc = try #require(AccountStateDocument.merged(b, c))
        let aBC = try #require(AccountStateDocument.merged(a, bc))

        #expect(ab == ba)
        #expect(abc == aBC)
        #expect(AccountStateDocument.merged(abc, abc) == abc)
        #expect(AccountStateDocument.merged(abc, a) == abc)
        #expect(try abc.encoded() == aBC.encoded())
    }

    @Test func theLatestChangeWins() throws {
        let documents = try samples()
        let ab = try #require(AccountStateDocument.merged(documents[0], documents[1]))
        let merged = try #require(AccountStateDocument.merged(ab, documents[2]))

        #expect(!merged.isHidden(photo))
        #expect(merged.value(for: .sharedLibraryEnabled) == false)
        // Equal times fall back to the device: "iphone" sorts after "ipad".
        #expect(merged.isHidden(other))
    }

    @Test func equalStampsWithDifferentContentNeverShareMore() throws {
        let stamp = AccountStateStamp(time: 7, deviceID: "clone", nonce: 9)
        let hidden = AccountStateRegister(value: true, stamp: stamp)
        let shown = AccountStateRegister(value: false, stamp: stamp)
        #expect(AccountStateDocument.winner(hidden, shown) == hidden)
        #expect(AccountStateDocument.winner(shown, hidden) == hidden)

        for other in [AccountStateJSONValue.bool(false), .object([:]), .null, .number("1")] {
            let on = AccountStateRegister(value: AccountStateJSONValue.bool(true), stamp: stamp)
            let off = AccountStateRegister(value: other, stamp: stamp)
            #expect(AccountStateDocument.winner(on, off) == off)
            #expect(AccountStateDocument.winner(off, on) == off)
        }
    }

    @Test func aSettingInAnotherUnicodeFormIsStoredInNormalizationFormC() throws {
        let key = AccountSettingKey<AccountStateJSONValue>(name: "text", encode: { $0 }, decode: { $0 })
        var composed = AccountStateDocument()
        try composed.setValue(.object(["\u{e9}": .string("\u{e9}")]), for: key, at: date(1), deviceID: "d", nonce: 1)
        var decomposed = AccountStateDocument()
        try decomposed.setValue(
            .object(["e\u{301}": .string("e\u{301}")]), for: key, at: date(1), deviceID: "d", nonce: 1)

        #expect(try composed.encoded() == decomposed.encoded())
        #expect(AccountStateDocument.merged(composed, decomposed) == composed)
    }
}

@Suite("Account state from newer or damaged data")
struct AccountStateRobustnessTests {
    @Test func fieldsEntriesAndSettingsFromANewerBuildSurviveARewriteAndAMerge() throws {
        let state = try document(
            """
            {"format":1,"hidden":[\(hiddenEntry("photo", true, time: 1, extra: #","futurePolicy":{"x":1}"#))],
             "settings":{"future.thing":{"value":{"a":1e400},"time":3,"device":"mac","nonce":"000000000000000b"}},
             "futureField":{"id":123456789012345678901234567890.000000000000000000001}}
            """)
        var changed = state
        try changed.setHidden(other, true, at: date(10), deviceID: "iphone")
        let merged = try #require(AccountStateDocument.merged(state, changed))

        let written = try text(merged)
        #expect(written.contains(#""futureField":{"id":123456789012345678901234567890.000000000000000000001}"#))
        #expect(written.contains(#""value":{"a":1e400}"#))
        #expect(written.contains(#""futurePolicy":{"x":1}"#))
        #expect(try AccountStateDocument(data: merged.encoded()) == merged)
    }

    @Test func aLaterChangeDropsTheEntryFieldsOfTheChangeItReplaces() throws {
        let state = try document(
            #"{"format":1,"hidden":[\#(hiddenEntry("photo", true, time: 1, extra: #","futurePolicy":{"x":1}"#))]}"#)
        var changed = state
        try changed.setHidden(photo, false, at: date(5), deviceID: "iphone")

        let merged = try #require(AccountStateDocument.merged(state, changed))
        #expect(merged.hiddenRegisters[photo]?.extensions.isEmpty == true)
        #expect(!merged.isHidden(photo))
    }

    @Test func aNewerFormatIsReadOnlyAndCountsAsUnknownState() throws {
        var state = try document(#"{"format":2,"hidden":"a new layout"}"#)

        #expect(!state.isSupported)
        #expect(!state.isUsable)
        #expect(throws: AccountStateReadOnlyError(format: 2)) { try state.encoded() }
        #expect(throws: AccountStateReadOnlyError(format: 2)) {
            try state.setHidden(photo, true, at: date(1), deviceID: "mac")
        }
        #expect(AccountStateDocument.merged(state, AccountStateDocument()) == nil)
        #expect(AccountStateDocument.merged(AccountStateDocument(), state) == nil)
        #expect(state.discardingDamage() == nil)
    }

    @Test(arguments: [
        "", "[]", "{}", #"{"format":0}"#, #"{"format":"1"}"#, #"{"format":1.0}"#, #"{"format":1e0}"#, "not json",
        #"{"format":1,"format":1}"#, #"{"format":1,"a":"\ud800"}"#, #"{"format":1} x"#, #"{"format":01}"#,
    ])
    func dataWithoutAReadableFormatIsNotADocument(json: String) {
        #expect(throws: AccountStateUnreadableError()) { try document(json) }
    }

    @Test(arguments: [
        // A hidden field of the wrong shape, even one that looks like an entry that shows its photo.
        #"{"format":1,"hidden":{"volumeID":"volume","nodeID":"photo","value":false,"time":1,"device":"d","nonce":"000000000000000a"}}"#,
        #"{"format":1,"hidden":"photo"}"#,
        #"{"format":1,"settings":[]}"#,
        // Damaged entries.
        #"{"format":1,"hidden":[null]}"#,
        #"{"format":1,"hidden":[{"volumeID":"volume","nodeID":"photo","value":"yes","time":1,"device":"mac","nonce":"000000000000000a"}]}"#,
        #"{"format":1,"settings":{"sharedLibrary.enabled":{"value":true,"time":1,"device":"mac"}}}"#,
        #"{"format":1,"settings":{"":{"value":true,"time":1,"device":"mac","nonce":"000000000000000a"}}}"#,
    ])
    func damageMakesTheDocumentUnusableInsteadOfBeingResolved(json: String) throws {
        var state = try document(json)

        #expect(state.isDamaged)
        #expect(!state.isUsable)
        #expect(throws: AccountStateDamagedError()) { try state.encoded() }
        #expect(throws: AccountStateDamagedError()) {
            try state.setHidden(photo, false, at: date(99), deviceID: "mac")
        }
        #expect(AccountStateDocument.merged(state, AccountStateDocument()) == nil)
        let repaired = try #require(state.discardingDamage())
        #expect(repaired.isUsable)
    }

    @Test func aStaleReadableCopyCannotResolveALaterDamagedHide() throws {
        let stale = try document(#"{"format":1,"hidden":[\#(hiddenEntry("photo", false, time: 10))]}"#)
        // A later hide whose device field became damaged.
        let damaged = try document(
            #"{"format":1,"hidden":[\#(hiddenEntry("photo", false, time: 10)),\#(hiddenEntry("photo", true, time: 20, device: ""))]}"#
        )

        #expect(damaged.isHidden(photo))
        #expect(damaged.hiddenPhotos == [photo])
        #expect(!damaged.isUsable)
        #expect(AccountStateDocument.merged(stale, damaged) == nil)
    }

    @Test(arguments: [
        "1.0000000000000000000000000000000000000001", "1.0", "1e0", "-1", "9223372036854775808", "1e400",
    ])
    func aTimeThatIsNotAPlainWholeNumberInRangeIsDamage(time: String) throws {
        let state = try document(
            #"{"format":1,"hidden":[{"volumeID":"volume","nodeID":"photo","value":false,"time":\#(time),"device":"mac","nonce":"000000000000000a"}]}"#
        )

        #expect(!state.isUsable)
        #expect(state.isHidden(photo))
    }

    @Test(arguments: [
        "000000000000000A", "00000000000000a", "0x0000000000000a", "-00000000000000a", "000000000000000g",
    ])
    func aNonceThatIsNotSixteenLowercaseHexDigitsIsDamage(nonce: String) throws {
        let state = try document(
            #"{"format":1,"hidden":[{"volumeID":"volume","nodeID":"photo","value":true,"time":1,"device":"mac","nonce":"\#(nonce)"}]}"#
        )
        #expect(!state.isUsable)
    }

    @Test func duplicateEntriesForOnePhotoKeepTheLaterOne() throws {
        let state = try document(
            #"{"format":1,"hidden":[\#(hiddenEntry("photo", false, time: 9)),\#(hiddenEntry("photo", true, time: 4))]}"#
        )

        #expect(state.isUsable)
        #expect(!state.isHidden(photo))
        #expect(AccountStateDocument.merged(state, state) == state)
    }
}

@Suite("Account state JSON codec")
struct AccountStateJSONTests {
    @Test func numbersKeepTheirExactText() throws {
        let parsed = try #require(value(#"[1e400,-0.5,12345678901234567890123456789012345678901234567890,1.0]"#))
        #expect(
            String(decoding: parsed.canonicalBytes, as: UTF8.self)
                == #"[1e400,-0.5,12345678901234567890123456789012345678901234567890,1.0]"#)
        #expect(value("1.0") != value("1"))
    }

    @Test(arguments: [
        "01", "1.", ".5", "+1", "1e", "--1", "NaN", "Infinity", "[1,]", "{\"a\":1,}", "\"\u{01}\"", "\"\\x\"",
        "\"\\ud800\"", "\"\\udc00\\ud800\"", "tru", "nul", "[", "{\"a\"}", "{1:2}",
    ])
    func invalidJSONIsRefused(json: String) {
        #expect(value(json) == nil)
    }

    @Test func invalidUTF8IsRefused() {
        #expect(AccountStateJSONValue(json: Data([0x22, 0xFF, 0x22])) == nil)
    }

    @Test func textThatIsNotInNormalizationFormCIsRefused() {
        #expect(value(#""e\u0301""#) == nil)
        #expect(value(#"{"e\u0301":0}"#) == nil)
        #expect(value(#""\u00e9""#) == .string("\u{e9}"))
        #expect(value(#"{"a":0,"a":1}"#) == nil)
    }

    @Test func escapesAndControlCharactersRoundTrip() throws {
        let parsed = try #require(value(#"["a\"b\\c\/d\b\f\n\r\t\u0001\ud83d\ude00"]"#))
        let reparsed = AccountStateJSONValue(json: Data(parsed.canonicalBytes))
        #expect(reparsed == parsed)
        #expect(parsed == .array([.string("a\"b\\c/d\u{08}\u{0C}\n\r\t\u{01}😀")]))
    }

    @Test func nestingBeyondTheLimitIsRefusedWhenReadingAndWhenChanging() throws {
        let limit = AccountStateJSONValue.maximumDepth
        #expect(value(String(repeating: "[", count: limit) + String(repeating: "]", count: limit)) != nil)
        #expect(value(String(repeating: "[", count: limit + 1) + String(repeating: "]", count: limit + 1)) == nil)

        var deep = AccountStateJSONValue.bool(true)
        for _ in 0..<200 { deep = .array([deep]) }
        let key = AccountSettingKey<AccountStateJSONValue>(name: "deep", encode: { $0 }, decode: { $0 })
        var state = AccountStateDocument()
        #expect(throws: AccountStateInvalidChangeError()) {
            try state.setValue(deep, for: key, at: date(1), deviceID: "mac")
        }
    }

    @Test func theDeepestSettingThatIsAcceptedReadsBack() throws {
        let key = AccountSettingKey<AccountStateJSONValue>(name: "deep", encode: { $0 }, decode: { $0 })
        func nested(_ levels: Int) -> AccountStateJSONValue {
            var value = AccountStateJSONValue.bool(true)
            for _ in 0..<levels { value = .array([value]) }
            return value
        }
        var state = AccountStateDocument()
        try state.setValue(nested(AccountStateJSONValue.maximumDepth - 3), for: key, at: date(1), deviceID: "mac")
        #expect(try AccountStateDocument(data: state.encoded()) == state)
        #expect(throws: AccountStateInvalidChangeError()) {
            try state.setValue(nested(AccountStateJSONValue.maximumDepth - 2), for: key, at: date(2), deviceID: "mac")
        }
    }

    @Test func textThatNormalizationWouldShortenIsRefused() {
        let key = AccountSettingKey<AccountStateJSONValue>(name: "text", encode: { $0 }, decode: { $0 })
        var state = AccountStateDocument()
        #expect(throws: AccountStateInvalidChangeError()) {
            try state.setValue(.string(String(repeating: "\u{0344}", count: 128)), for: key, at: date(1), deviceID: "d")
        }
    }

    @Test func aSettingWithInvalidNumberTextIsRefused() {
        let key = AccountSettingKey<AccountStateJSONValue>(name: "n", encode: { $0 }, decode: { $0 })
        var state = AccountStateDocument()
        #expect(throws: AccountStateInvalidChangeError()) {
            try state.setValue(.number("1e"), for: key, at: date(1), deviceID: "mac")
        }
    }
}

@Suite("Account state limits")
struct AccountStateLimitTests {
    @Test(arguments: [Double.nan, .infinity, -1, 9.3e15])
    func aDateOutsideTheStoredRangeIsRefused(seconds: Double) {
        var state = AccountStateDocument()
        #expect(throws: AccountStateInvalidChangeError()) {
            try state.setHidden(photo, true, at: Date(timeIntervalSince1970: seconds), deviceID: "mac")
        }
        #expect(state == AccountStateDocument())
    }

    @Test(arguments: ["", String(repeating: "a", count: 257)])
    func anInvalidDeviceIDIsRefused(deviceID: String) {
        var state = AccountStateDocument()
        #expect(throws: AccountStateInvalidChangeError()) {
            try state.setValue(true, for: .sharedLibraryEnabled, at: date(1), deviceID: deviceID)
        }
    }

    @Test func aPhotoWithAnEmptyIdentifierIsRefused() {
        var state = AccountStateDocument()
        for photo in [PhotoUID(volumeID: "", nodeID: "photo"), PhotoUID(volumeID: "volume", nodeID: "")] {
            #expect(throws: AccountStateInvalidChangeError()) {
                try state.setHidden(photo, true, at: date(1), deviceID: "mac")
            }
        }
    }

    @Test func aDeviceIDIsMeasuredAfterNormalizationSoItAlwaysReadsBack() throws {
        // U+0958 takes three bytes and becomes two three-byte scalars in normalization form C.
        var state = AccountStateDocument()
        #expect(throws: AccountStateInvalidChangeError()) {
            try state.setHidden(photo, true, at: date(1), deviceID: String(repeating: "\u{0958}", count: 85))
        }
        try state.setHidden(photo, true, at: date(1), deviceID: String(repeating: "\u{0958}", count: 42))
        #expect(try AccountStateDocument(data: state.encoded()).isUsable)
    }

    @Test func aClockThatCannotAdvanceRefusesTheChangeInsteadOfCrashing() throws {
        var state = try document(
            #"{"format":1,"hidden":[\#(hiddenEntry("photo", true, time: 9_223_372_036_854_775_807))]}"#)
        #expect(throws: AccountStateInvalidChangeError()) {
            try state.setHidden(photo, false, at: date(1), deviceID: "iphone")
        }
        #expect(state.isHidden(photo))
    }

    @Test func largeTimesKeepEveryDigit() throws {
        let state = try document(
            #"{"format":1,"hidden":[\#(hiddenEntry("photo", true, time: 9_007_199_254_740_993))]}"#)

        #expect(state.hiddenRegisters[photo]?.stamp.time == 9_007_199_254_740_993)
        #expect(try text(state).contains("9007199254740993"))
    }
}
