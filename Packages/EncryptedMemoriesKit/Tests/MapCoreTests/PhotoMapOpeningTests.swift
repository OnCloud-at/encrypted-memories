import Foundation
import MapKit
import MediaLocationCore
import PhotosCore
import Testing

@testable import MapCore

@Suite @MainActor struct PhotoMapOpeningTests {
    @Test(arguments: [false, true])
    func openingFramesBeforePublishingPins(initiallyEmpty: Bool) async throws {
        let index = PhotoLocationIndex()
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        map.setRegion(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 240)), animated: false)
        let loader = PhotoMapAnnotationLoader(index: index, policy: .standard, onRemoved: { _ in })
        if initiallyEmpty {
            loader.attach(map)
            await loader.waitForFramingForTesting()
            await loader.waitForReloadForTesting()
            #expect(map.annotations.isEmpty)
        }
        let point = PhotoCoordinate(
            uid: PhotoUID(volumeID: "test", nodeID: "point"), latitude: 20, longitude: 30, date: .now)
        index.replaceAll([point])
        let gate = FramingPause()
        loader.beforeFramingForTesting = { await gate.pause() }
        if initiallyEmpty {
            loader.refreshIfChanged(revision: index.revision)
        } else {
            loader.attach(map)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.entered && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        defer { gate.released = true }
        try #require(gate.entered)
        loader.reloadVisible()
        await loader.waitForReloadForTesting()
        #expect(map.annotations.isEmpty, "The first pins must wait for the dense-core frame")
        gate.released = true
        await loader.waitForFramingForTesting()
        await loader.waitForReloadForTesting()
        #expect(map.annotations.compactMap { $0 as? PhotoMapAnnotation }.count == 1)
        #expect(abs(map.region.center.latitude - point.latitude) < 0.1)
        #expect(abs(map.region.center.longitude - point.longitude) < 0.1)
    }
}

@MainActor private final class FramingPause {
    var entered = false
    var released = false
    func pause() async {
        entered = true
        let deadline = ContinuousClock.now + .seconds(10)
        while !released && ContinuousClock.now < deadline && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
