import Foundation
import PhotosCore
import XCTest

final class AppRouteGateTests: XCTestCase {
    func testOnlyAUsableAccountWithAReadyLibraryAndNoModalOpensARoute() {
        // session, libraryReady, presentationBlocked, opens
        let rows: [(AppRouteSessionState, Bool, Bool, Bool)] = [
            (.restoring, false, false, false), (.restoring, false, true, false),
            (.restoring, true, false, false), (.restoring, true, true, false),
            (.signedOut, false, false, false), (.signedOut, false, true, false),
            (.signedOut, true, false, false), (.signedOut, true, true, false),
            (.usable, false, false, false), (.usable, false, true, false),
            (.usable, true, false, true), (.usable, true, true, false),
        ]
        for (session, libraryReady, presentationBlocked, opens) in rows {
            XCTAssertEqual(
                AppRouteGate.opens(
                    session: session, libraryReady: libraryReady, presentationBlocked: presentationBlocked),
                opens, "\(session) \(libraryReady) \(presentationBlocked)")
        }
    }
}

@MainActor
final class AppRouteInboxTests: XCTestCase {
    private let window = UUID()
    private let otherWindow = UUID()

    private func open(
        _ inbox: AppRouteInbox,
        window: UUID? = nil,
        isActiveWindow: Bool = true,
        libraryReady: Bool = true,
        presentationBlocked: Bool = false
    ) -> AppRoute? {
        inbox.open(
            window: window ?? self.window,
            isActiveWindow: isActiveWindow,
            libraryReady: libraryReady,
            presentationBlocked: presentationBlocked
        )
    }

    func testRouteDuringSessionRestoreThatEndsSignedInOpensOnce() {
        let inbox = AppRouteInbox()
        XCTAssertEqual(inbox.session, .restoring)
        inbox.receive(.collection(.favorites), for: .activeWindow)
        XCTAssertNil(open(inbox))

        inbox.update(session: .usable)
        XCTAssertEqual(open(inbox), .collection(.favorites))
        XCTAssertNil(inbox.pending)
        XCTAssertNil(open(inbox))
    }

    func testRouteDuringSessionRestoreThatEndsSignedOutIsDropped() {
        let inbox = AppRouteInbox()
        inbox.receive(.library, for: .window(window))
        inbox.update(session: .signedOut)
        XCTAssertNil(inbox.pending)

        inbox.update(session: .usable)
        XCTAssertNil(open(inbox))
    }

    func testRouteWhileSignedOutOrSigningInIsDropped() {
        let inbox = AppRouteInbox()
        inbox.update(session: .signedOut)
        inbox.receive(.collection(.videos), for: .activeWindow)
        XCTAssertNil(inbox.pending)

        inbox.update(session: .usable)
        XCTAssertNil(open(inbox))
    }

    func testSignOutDropsAPendingRoute() {
        let inbox = AppRouteInbox()
        inbox.update(session: .usable)
        inbox.receive(.library, for: .activeWindow)
        inbox.update(session: .signedOut)
        XCTAssertNil(inbox.pending)

        inbox.update(session: .restoring)
        inbox.update(session: .usable)
        XCTAssertNil(open(inbox))
    }

    func testRouteWaitsWhileTheLibraryLoadsOrIsRebuilt() {
        let inbox = AppRouteInbox()
        inbox.update(session: .usable)
        inbox.receive(.collection(.raw), for: .activeWindow)
        XCTAssertNil(open(inbox, libraryReady: false))
        XCTAssertEqual(inbox.pending?.route, .collection(.raw))
        XCTAssertEqual(open(inbox, libraryReady: true), .collection(.raw))
    }

    func testRouteWaitsWhileAViewerOrSheetIsOpenThenOpensOnceAfterItCloses() {
        let inbox = AppRouteInbox()
        inbox.update(session: .usable)
        inbox.receive(.library, for: .window(window))
        XCTAssertNil(open(inbox, presentationBlocked: true))
        XCTAssertEqual(inbox.pending?.route, .library)
        XCTAssertEqual(open(inbox, presentationBlocked: false), .library)
        XCTAssertNil(open(inbox, presentationBlocked: false))
    }

    func testNewerRouteReplacesAnOlderPendingRoute() {
        let inbox = AppRouteInbox()
        inbox.receive(.collection(.videos), for: .activeWindow)
        inbox.receive(.library, for: .window(otherWindow))
        inbox.receive(.collection(.raw), for: .window(window))
        inbox.update(session: .usable)
        XCTAssertNil(open(inbox, window: otherWindow))
        XCTAssertEqual(open(inbox, window: window), .collection(.raw))
        XCTAssertNil(open(inbox, window: window))
    }

    func testALinkOpensOnlyInTheWindowThatReceivedIt() {
        let inbox = AppRouteInbox()
        inbox.update(session: .usable)
        inbox.receive(.library, for: .window(window))
        XCTAssertNil(open(inbox, window: otherWindow, isActiveWindow: true))
        XCTAssertEqual(open(inbox, window: window, isActiveWindow: false), .library)
    }

    func testAnActionOpensOnlyInTheActiveWindowAndOnlyOnce() {
        let inbox = AppRouteInbox()
        inbox.update(session: .usable)
        inbox.receive(.library, for: .activeWindow)
        XCTAssertNil(open(inbox, window: otherWindow, isActiveWindow: false))
        let first = open(inbox, window: window, isActiveWindow: true)
        let second = open(inbox, window: otherWindow, isActiveWindow: true)
        XCTAssertEqual([first, second].compactMap { $0 }, [.library])
    }

    func testEveryArrivalIsCountedAlsoWhenTheRouteIsDropped() {
        let inbox = AppRouteInbox()
        XCTAssertEqual(inbox.arrivals, 0)
        inbox.receive(.library, for: .activeWindow)
        inbox.update(session: .signedOut)
        inbox.receive(.collection(.videos), for: .activeWindow)
        inbox.noteArrival()
        XCTAssertEqual(inbox.arrivals, 3)
        XCTAssertNil(inbox.pending)
    }

    func testClosingTheTargetWindowDropsItsLink() {
        let inbox = AppRouteInbox()
        inbox.receive(.library, for: .window(window))
        inbox.windowClosed(otherWindow)
        XCTAssertNotNil(inbox.pending)
        inbox.windowClosed(window)
        XCTAssertNil(inbox.pending)

        inbox.receive(.library, for: .activeWindow)
        inbox.windowClosed(window)
        XCTAssertNotNil(inbox.pending)
    }
}
