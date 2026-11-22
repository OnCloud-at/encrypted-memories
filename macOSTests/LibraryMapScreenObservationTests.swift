import Foundation
import MapFeature
import MapKit
import MediaLocationCore
import Observation
import PhotosCore
import SwiftUI
import XCTest

final class LibraryMapScreenObservationTests: XCTestCase {
    @MainActor func testScreenBodyObservesIndexRevision() {
        let index = PhotoLocationIndex()
        let screen = LibraryMapScreen(
            LibraryMapView(
                index: index, thumbnail: { _ in nil }, loadThumbnail: { _ in nil }, onSelectPhoto: { _ in }))
        let probe = RevisionObservationProbe()
        withObservationTracking {
            _ = screen.body
        } onChange: {
            probe.recordChange()
        }
        index.merge([
            PhotoCoordinate(
                uid: PhotoUID(volumeID: "test", nodeID: "revision"),
                latitude: 20, longitude: 30, date: Date(timeIntervalSince1970: 1_700_000_000))
        ])
        XCTAssertTrue(probe.changed, "The screen body must observe an index revision")
    }

    @MainActor func testNewIndexRevisionUpdatesMountedMap() async throws {
        let index = PhotoLocationIndex()
        func coordinate(_ id: String, _ latitude: Double) -> PhotoCoordinate {
            PhotoCoordinate(
                uid: PhotoUID(volumeID: "test", nodeID: id),
                latitude: latitude, longitude: 30, date: Date(timeIntervalSince1970: 1_700_000_000))
        }
        index.replaceAll([coordinate("first", 20), coordinate("second", 20.01)])
        for _ in 0..<200 {
            if index.placeRevision > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard index.placeRevision > 0 else {
            XCTFail("The initial location evidence must be ready before the screen mounts")
            return
        }

        let screen = LibraryMapScreen(
            LibraryMapView(
                index: index, thumbnail: { _ in nil }, loadThumbnail: { _ in nil }, onSelectPhoto: { _ in }))
        let host = NSHostingView(rootView: screen)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }

        func findMap(_ view: NSView) -> MKMapView? {
            if let map = view as? MKMapView { return map }
            return view.subviews.lazy.compactMap { findMap($0) }.first
        }
        let map = try XCTUnwrap(findMap(host), "The production screen must mount its MapKit view")
        XCTAssertTrue(map.window === window, "The map must be attached to the host window")
        guard map.window === window else { return }
        // The counts depend on how MapKit clusters these coordinates: two pins after the first load, three after the
        // new revision. A growth check alone would also pass on the first load finishing late, so the exact counts
        // keep the test tied to the revision. The wait polls for up to ten seconds, because the map loads its pins
        // on its own schedule.
        func waitForPins(_ expected: Int) async throws -> Bool {
            for _ in 0..<200 {
                if map.annotations.count == expected { return true }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTFail("Expected \(expected) map annotations, got \(map.annotations.count)")
            return false
        }
        guard try await waitForPins(2) else { return }
        let oldRevision = index.revision
        XCTAssertEqual(index.merge([coordinate("third", 20.005)]).count, 1)
        XCTAssertGreaterThan(index.revision, oldRevision)
        _ = try await waitForPins(3)
    }
}

private final class RevisionObservationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var changed: Bool { lock.withLock { value } }
    func recordChange() { lock.withLock { value = true } }
}
