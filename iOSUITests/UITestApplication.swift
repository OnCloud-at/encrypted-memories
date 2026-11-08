import XCTest

/// Creates the app for every UI test. XCTest launches it with `OS_ACTIVITY_DT_MODE` set and stdio on a pseudo
/// terminal, so the system log, including XCTest's own per-attribute automation log inside the app, is mirrored to
/// stderr. Every accessibility query then writes thousands of lines from the app's main thread; on a loaded host
/// those writes block and the query times out. The system log keeps every entry for `log stream` and Console.
enum UITestApplication {
    static func make() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OS_ACTIVITY_DT_MODE"] = "NO"
        return app
    }
}

extension XCUIElement {
    /// Waits up to `timeout` seconds until `format`, an `NSPredicate` format, holds for this element.
    func wait(until format: String, timeout: TimeInterval) -> XCTWaiter.Result {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout)
    }

    /// Waits up to `timeout` seconds until this element no longer exists.
    func waitUntilGone(timeout: TimeInterval) -> XCTWaiter.Result {
        wait(until: "exists == false", timeout: timeout)
    }
}
