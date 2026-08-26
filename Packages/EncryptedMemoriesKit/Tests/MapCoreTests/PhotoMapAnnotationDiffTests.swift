import Foundation
import PhotosCore
import Testing

@testable import MapCore

private func uid(_ nodeID: String) -> PhotoUID {
    PhotoUID(volumeID: "v", nodeID: nodeID)
}

private func cell(
    _ members: [String],
    hero: String = "hero",
    latitudeIndex: Int = 10,
    longitudeIndex: Int = 20
) -> AggregatedCoordinate {
    AggregatedCoordinate(
        cellID: PhotoLocationCellID(
            latitudeStepExponent: -2,
            longitudeCellCountExponent: 10,
            latitudeIndex: latitudeIndex,
            longitudeIndex: longitudeIndex
        ),
        memberUIDs: members.map(uid),
        latitude: 47,
        longitude: 13,
        uid: uid(hero)
    )
}

@Suite struct PhotoMapAnnotationDiffTests {
    private var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test func growingMembershipReplacesSameHeroCell() {
        let old = cell(["a", "b"], hero: "b")
        let updated = cell(["a", "b"] + (0..<4_998).map { "p\($0)" }, hero: "b")

        let diff = PhotoMapAnnotationDiff.make(
            current: [old.cellID: old],
            desired: [updated]
        )

        #expect(diff.removedCellIDs == [old.cellID])
        #expect(diff.addedCells == [updated])
        #expect(diff.sourceCellIDByAddedCellID[updated.cellID] == old.cellID)
        #expect(diff.destinationCellIDByRemovedCellID[old.cellID] == updated.cellID)
    }

    @Test func identicalCellProducesNoMapChurn() {
        let unchanged = cell(["a", "b"])
        let diff = PhotoMapAnnotationDiff.make(
            current: [unchanged.cellID: unchanged],
            desired: [unchanged]
        )

        #expect(diff.removedCellIDs.isEmpty)
        #expect(diff.addedCells.isEmpty)
        #expect(diff.sourceCellIDByAddedCellID.isEmpty)
        #expect(diff.destinationCellIDByRemovedCellID.isEmpty)
    }

    @Test func splitCellsStartAtTheOldCellContainingEachNewHero() {
        let old = cell(["a", "b", "c", "d"], hero: "d")
        let first = cell(["a", "b"], hero: "b", latitudeIndex: 20, longitudeIndex: 40)
        let second = cell(["c", "d"], hero: "d", latitudeIndex: 21, longitudeIndex: 40)

        let diff = PhotoMapAnnotationDiff.make(current: [old.cellID: old], desired: [first, second])

        #expect(diff.sourceCellIDByAddedCellID[first.cellID] == old.cellID)
        #expect(diff.sourceCellIDByAddedCellID[second.cellID] == old.cellID)
        #expect(diff.destinationCellIDByRemovedCellID[old.cellID] == second.cellID)
    }

    @Test func mergedCellReceivesEveryOldCellThatRetainsItsHero() {
        let first = cell(["a", "b"], hero: "b", latitudeIndex: 20, longitudeIndex: 40)
        let second = cell(["c", "d"], hero: "d", latitudeIndex: 21, longitudeIndex: 40)
        let merged = cell(["a", "b", "c", "d"], hero: "d")

        let diff = PhotoMapAnnotationDiff.make(
            current: [first.cellID: first, second.cellID: second],
            desired: [merged]
        )

        #expect(diff.sourceCellIDByAddedCellID[merged.cellID] == second.cellID)
        #expect(diff.destinationCellIDByRemovedCellID[first.cellID] == merged.cellID)
        #expect(diff.destinationCellIDByRemovedCellID[second.cellID] == merged.cellID)
    }

    @Test func unrelatedViewportCellsDoNotInventAMorphRelationship() {
        let old = cell(["old"], hero: "old")
        let fresh = cell(["new"], hero: "new", latitudeIndex: 30, longitudeIndex: 60)

        let diff = PhotoMapAnnotationDiff.make(current: [old.cellID: old], desired: [fresh])

        #expect(diff.sourceCellIDByAddedCellID.isEmpty)
        #expect(diff.destinationCellIDByRemovedCellID.isEmpty)
    }

    @Test func nativeHostsDoNotRegroupOrDeclutterFinalCoreCells() throws {
        let viewPaths = [
            "Packages/EncryptedMemoriesKit/Sources/MapFeature/PhotoAnnotationViews.swift",
            "Packages/EncryptedMemoriesKit/Sources/MapUIKitAdapter/UIKitPhotoAnnotationViews.swift",
        ]
        for path in viewPaths {
            let text = try source(path)
            #expect(text.contains("clusteringIdentifier = nil"))
            #expect(text.contains("displayPriority = .required"))
            #expect(!text.contains("clusteringIdentifier = \"photo\""))
            #expect(!text.contains("displayPriority = .defaultLow"))
        }

        let hostPaths = [
            "Packages/EncryptedMemoriesKit/Sources/MapFeature/LibraryMapView.swift",
            "Packages/EncryptedMemoriesKit/Sources/MapUIKitAdapter/UIKitLibraryMapHostView.swift",
        ]
        for path in hostPaths {
            #expect(
                try source(path).contains("isPitchEnabled = false"),
                "the degree-based Core grid requires an unpitched native map")
        }

        let roots = [
            repoRoot.appendingPathComponent("Packages/EncryptedMemoriesKit/Sources/MapFeature"),
            repoRoot.appendingPathComponent("Packages/EncryptedMemoriesKit/Sources/MapUIKitAdapter"),
        ]
        let forbidden = [
            "MKClusterAnnotation",
            "MKMapViewDefaultClusterAnnotationViewReuseIdentifier",
            "clusteringIdentifier = \"photo\"",
            "displayPriority = .defaultLow",
        ]
        var scanned = 0
        for root in roots {
            guard
                let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: nil
                )
            else { continue }
            for case let file as URL in enumerator where file.pathExtension == "swift" {
                scanned += 1
                let text = try String(contentsOf: file, encoding: .utf8)
                for token in forbidden {
                    #expect(!text.contains(token), "final Core cells must not regain '\(token)' in \(file.path)")
                }
            }
        }
        #expect(scanned > 0)
    }

    @Test func macOSCountBadgeDoesNotInterceptMapAnnotationClicks() throws {
        let text = try source("Packages/EncryptedMemoriesKit/Sources/MapFeature/PhotoAnnotationViews.swift")
        #expect(text.contains("private final class NonHitTestingTextField: NSTextField"))
        #expect(text.contains("override func hitTest(_ point: NSPoint) -> NSView? { nil }"))
        #expect(text.contains("private let countLabel = NonHitTestingTextField(labelWithString: \"\")"))
        #expect(
            !text.contains("private let countLabel = NSTextField(labelWithString: \"\")"),
            "a decorative AppKit text field otherwise wins hit-testing over the MapKit annotation")
    }
}
