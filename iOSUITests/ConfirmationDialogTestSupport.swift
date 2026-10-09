import XCTest

enum ConfirmationDialogTestError: Error {
    case notHittable(String)
    case notAcknowledged(String)
}

extension XCUIApplication {
    /// The system dialog can list an action twice; wait for a hittable copy instead of using a hidden fallback.
    func hittableDialogButton(_ identifier: String) throws -> XCUIElement {
        let matches = buttons.matching(identifier: identifier)
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in matches.allElementsBoundByIndex.contains { $0.isHittable } },
            object: nil
        )
        guard XCTWaiter.wait(for: [ready], timeout: 5) == .completed,
            let button = matches.allElementsBoundByIndex.first(where: { $0.isHittable })
        else { throw ConfirmationDialogTestError.notHittable(identifier) }
        return button
    }

    /// Closing the dialog acknowledges the decision. Repeat only a tap that the dialog did not acknowledge.
    func tapDialogButton(
        _ identifier: String, tap: (XCUIElement) -> Void = { $0.tap() }
    ) throws {
        for attempt in 0..<2 {
            if attempt > 0, !buttons[identifier].firstMatch.exists { return }
            tap(try hittableDialogButton(identifier))
            let acknowledged = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: buttons[identifier].firstMatch
            )
            // Hosted snapshot stalls reached 19.3 s; allow several cycles before retrying input.
            if XCTWaiter.wait(for: [acknowledged], timeout: 45) == .completed { return }
        }
        throw ConfirmationDialogTestError.notAcknowledged(identifier)
    }
}
