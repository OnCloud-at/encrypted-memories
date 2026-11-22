import Foundation
import Testing

@testable import PhotosCore

@MainActor
@Suite struct SupportReportPreparationTests {
    private struct BuildFailure: Error {}

    private final class Delivered: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Data] = []
        var values: [Data] { lock.withLock { stored } }
        func record(_ data: Data) { lock.withLock { stored.append(data) } }
    }

    private let report = Data("report".utf8)

    @Test func aBuiltReportIsHandedToTheDeliveryAndItsOutcomeIsReturned() async {
        let preparation = SupportReportPreparation(makeData: { Data("report".utf8) })
        let delivered = Delivered()

        let outcome = await preparation.prepare { data in
            delivered.record(data)
            return .delivered
        }

        #expect(outcome == .delivered)
        #expect(delivered.values == [report])
    }

    @Test func aDismissedSavePanelIsNotAFailure() async {
        let preparation = SupportReportPreparation(makeData: { Data("report".utf8) })

        let outcome = await preparation.prepare { _ in .dismissed }

        #expect(outcome == .dismissed)
    }

    @Test func aDeliveryThatCannotWriteIsAFailure() async {
        let preparation = SupportReportPreparation(makeData: { Data("report".utf8) })

        let returned = await preparation.prepare { _ in .failed }

        #expect(returned == .failed)
    }

    @Test func aDeliveryThatThrowsIsAFailure() async {
        let preparation = SupportReportPreparation(makeData: { Data("report".utf8) })

        let outcome = await preparation.prepare { _ in throw BuildFailure() }

        #expect(outcome == .failed)
        #expect(!preparation.isPreparing)
    }

    @Test func aReportThatCannotBeBuiltIsAFailureAndDeliversNothing() async {
        let preparation = SupportReportPreparation(makeData: { throw BuildFailure() })
        let delivered = Delivered()

        let outcome = await preparation.prepare { data in
            delivered.record(data)
            return .delivered
        }

        #expect(outcome == .failed)
        #expect(delivered.values.isEmpty)
        #expect(!preparation.isPreparing)
    }

    @Test func thePreparationShowsItselfWhileTheDeliveryRunsAndEndsWithIt() async {
        let preparation = SupportReportPreparation(makeData: { Data("report".utf8) })
        var duringDelivery: Bool?

        _ = await preparation.prepare { _ in
            duringDelivery = preparation.isPreparing
            return .delivered
        }

        #expect(duringDelivery == true)
        #expect(!preparation.isPreparing)
    }

    @Test func aSecondRequestWhileOneIsRunningDoesNothing() async {
        let preparation = SupportReportPreparation(makeData: { Data("report".utf8) })
        let delivered = Delivered()
        var nested: SupportReportPreparation.Delivery?
        var nestedWasAnswered = false

        let outer = await preparation.prepare { data in
            delivered.record(data)
            nested = await preparation.prepare { inner in
                delivered.record(inner)
                return .delivered
            }
            nestedWasAnswered = true
            return .delivered
        }

        #expect(outer == .delivered)
        #expect(nestedWasAnswered)
        #expect(nested == nil, "the second request is refused")
        #expect(delivered.values == [report], "only the first request delivers")
    }

    @Test func onlyAnAcceptedRequestRunsItsStartAction() async {
        let preparation = SupportReportPreparation(makeData: { Data("report".utf8) })
        var starts: [String] = []

        _ = await preparation.prepare(
            onStart: { starts.append("outer") },
            deliver: { _ in
                _ = await preparation.prepare(onStart: { starts.append("refused") }, deliver: { _ in .delivered })
                return .delivered
            })

        #expect(starts == ["outer"], "a refused request must not run its start action")
    }

    @Test func theStartActionRunsBeforeTheReportIsBuilt() async {
        var order: [String] = []
        let preparation = SupportReportPreparation(makeData: { Data("report".utf8) })

        _ = await preparation.prepare(
            onStart: { order.append("start") },
            deliver: { _ in
                order.append("deliver")
                return .delivered
            })

        #expect(order == ["start", "deliver"])
    }

    @Test func aFailedPreparationDoesNotBlockTheNextOne() async {
        let preparation = SupportReportPreparation(makeData: { Data("report".utf8) })
        _ = await preparation.prepare { _ in throw BuildFailure() }

        let outcome = await preparation.prepare { _ in .delivered }

        #expect(outcome == .delivered)
    }
}
