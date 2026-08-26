import Foundation
import MapKit
import MediaLocationCore
import PhotosCore
import QuartzCore

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

struct PhotoMapAnnotationDiff: Equatable, Sendable {
    let removedCellIDs: Set<PhotoLocationCellID>
    let addedCells: [AggregatedCoordinate]
    /// A new cell starts where the old cell containing its hero was shown. Looking up only bounded display-cell
    /// heroes keeps the transition mapping O(member count) without building a second whole-library UID map.
    let sourceCellIDByAddedCellID: [PhotoLocationCellID: PhotoLocationCellID]
    /// An old cell exits toward the new cell that still contains its hero. Merge and split transitions therefore
    /// preserve semantic photo identity instead of sliding toward an unrelated nearest pin.
    let destinationCellIDByRemovedCellID: [PhotoLocationCellID: PhotoLocationCellID]

    static func make(
        current: [PhotoLocationCellID: AggregatedCoordinate],
        desired cells: [AggregatedCoordinate]
    ) -> PhotoMapAnnotationDiff {
        let desired = Dictionary(uniqueKeysWithValues: cells.map { ($0.cellID, $0) })
        var removed = Set(current.keys).subtracting(desired.keys)
        var added = cells.filter { current[$0.cellID] == nil }

        for (cellID, oldCell) in current {
            guard let newCell = desired[cellID], newCell != oldCell else { continue }
            removed.insert(cellID)
            added.append(newCell)
        }
        let addedHeroUIDs = Set(added.map(\.uid))
        var oldCellIDByAddedHeroUID: [PhotoUID: PhotoLocationCellID] = [:]
        oldCellIDByAddedHeroUID.reserveCapacity(addedHeroUIDs.count)
        if !addedHeroUIDs.isEmpty {
            for oldCell in current.values {
                for memberUID in oldCell.memberUIDs where addedHeroUIDs.contains(memberUID) {
                    oldCellIDByAddedHeroUID[memberUID] = oldCell.cellID
                }
            }
        }
        let sourceCellIDByAddedCellID = Dictionary(
            uniqueKeysWithValues: added.compactMap { cell in
                oldCellIDByAddedHeroUID[cell.uid].map { (cell.cellID, $0) }
            })

        let removedHeroByUID = Dictionary(
            uniqueKeysWithValues: removed.compactMap { cellID in
                current[cellID].map { ($0.uid, cellID) }
            })
        let removedHeroUIDs = Set(removedHeroByUID.keys)
        var destinationCellIDByRemovedCellID: [PhotoLocationCellID: PhotoLocationCellID] = [:]
        destinationCellIDByRemovedCellID.reserveCapacity(removed.count)
        if !removedHeroUIDs.isEmpty {
            for newCell in cells {
                for memberUID in newCell.memberUIDs where removedHeroUIDs.contains(memberUID) {
                    if let oldCellID = removedHeroByUID[memberUID] {
                        destinationCellIDByRemovedCellID[oldCellID] = newCell.cellID
                    }
                }
            }
        }

        return PhotoMapAnnotationDiff(
            removedCellIDs: removed,
            addedCells: added,
            sourceCellIDByAddedCellID: sourceCellIDByAddedCellID,
            destinationCellIDByRemovedCellID: destinationCellIDByRemovedCellID
        )
    }
}

/// Shared MapKit annotation engine used by the macOS and iOS/iPadOS hosts.
@MainActor
public final class PhotoMapAnnotationLoader {
    private static let transitionDuration: CFTimeInterval = 0.22
    private static let resizeTransitionWindow: CFTimeInterval = 0.6

    private let index: PhotoLocationIndex
    private let policy: PhotoLocationVisibleCoordinatePolicy
    private weak var mapView: MKMapView?

    private var cellsByID: [PhotoLocationCellID: AggregatedCoordinate] = [:]
    private var annotationByCellID: [PhotoLocationCellID: PhotoMapAnnotation] = [:]
    private var annotationByUID: [PhotoUID: PhotoMapAnnotation] = [:]
    private var lastRevision = Int.min
    private var didFrame = false
    private var lastPlan: PhotoLocationAggregationPlan?
    private var lastViewportSize: PhotoLocationViewportSize?
    private var resizeTransitionDeadline: CFTimeInterval = 0
    private var reloadGeneration = 0
    private var reloadTask: Task<Void, Never>?

    private let onRemoved: (Set<PhotoUID>) -> Void

    public init(
        index: PhotoLocationIndex,
        policy: PhotoLocationVisibleCoordinatePolicy,
        onRemoved: @escaping (Set<PhotoUID>) -> Void
    ) {
        self.index = index
        self.policy = policy
        self.onRemoved = onRemoved
    }

    deinit { reloadTask?.cancel() }

    public func attach(_ mapView: MKMapView) {
        self.mapView = mapView
        frameToDenseCoreIfNeeded()
        DispatchQueue.main.async { [weak self] in self?.reloadVisible() }
    }

    public func refreshIfChanged(revision: Int) {
        guard revision != lastRevision else { return }
        lastRevision = revision
        lastPlan = nil
        frameToDenseCoreIfNeeded()
        reloadVisible()
    }

    public func annotation(for uid: PhotoUID) -> PhotoMapAnnotation? { annotationByUID[uid] }

    public func frameToDenseCoreIfNeeded() {
        guard !didFrame, let mapView, !index.coordinates.isEmpty,
            let box = PhotoLocationFraming.denseBoundingBox(for: index.coordinates)
        else { return }
        let a = MKMapPoint(CLLocationCoordinate2D(latitude: box.minLatitude, longitude: box.minLongitude))
        let b = MKMapPoint(CLLocationCoordinate2D(latitude: box.maxLatitude, longitude: box.maxLongitude))
        let rect = MKMapRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        guard !rect.isNull else { return }
        #if canImport(UIKit)
            let padding = UIEdgeInsets(top: 80, left: 80, bottom: 80, right: 80)
        #else
            let padding = NSEdgeInsets(top: 80, left: 80, bottom: 80, right: 80)
        #endif
        mapView.setVisibleMapRect(rect, edgePadding: padding, animated: false)
        didFrame = true
    }

    /// Snapshot the value-type index on the main actor, then filter and aggregate in the cancellable
    /// detached task. Only the small annotation delta returns to the main actor.
    public func reloadVisible() {
        guard let mapView else { return }
        let region = mapView.region
        let viewport = PhotoLocationViewport(
            centerLatitude: region.center.latitude,
            centerLongitude: region.center.longitude,
            latitudeDelta: region.span.latitudeDelta,
            longitudeDelta: region.span.longitudeDelta
        )
        let viewportSize = PhotoLocationViewportSize(
            widthPoints: Double(mapView.bounds.width),
            heightPoints: Double(mapView.bounds.height)
        )
        if let lastViewportSize, lastViewportSize != viewportSize {
            resizeTransitionDeadline = CACurrentMediaTime() + Self.resizeTransitionWindow
        }
        lastViewportSize = viewportSize
        guard let plan = policy.aggregationPlan(for: viewport, viewportSize: viewportSize),
            lastPlan != plan
        else { return }
        lastPlan = plan

        let query = index.querySnapshot()
        let policy = self.policy
        let currentCells = cellsByID
        let animateResizeTransition =
            !currentCells.isEmpty
            && CACurrentMediaTime() <= resizeTransitionDeadline
            && !Self.reduceMotionEnabled
        reloadGeneration &+= 1
        let generation = reloadGeneration
        reloadTask?.cancel()
        reloadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let coordinates = query.coordinates(in: plan.boundingBox)
            let cells = policy.aggregatedCoordinates(from: coordinates, using: plan)
            guard !Task.isCancelled else { return }
            let diff = PhotoMapAnnotationDiff.make(current: currentCells, desired: cells)
            guard !Task.isCancelled else { return }
            await self?.applyCells(
                cells,
                diff: diff,
                previousCells: currentCells,
                generation: generation,
                animateResizeTransition: animateResizeTransition
            )
        }
    }

    private func applyCells(
        _ cells: [AggregatedCoordinate],
        diff: PhotoMapAnnotationDiff,
        previousCells: [PhotoLocationCellID: AggregatedCoordinate],
        generation: Int,
        animateResizeTransition: Bool
    ) {
        guard generation == reloadGeneration, let mapView else { return }
        let desiredCellByID = Dictionary(uniqueKeysWithValues: cells.map { ($0.cellID, $0) })

        if !diff.removedCellIDs.isEmpty {
            let stale = diff.removedCellIDs.compactMap { annotationByCellID[$0] }
            let removedUIDs = Set(stale.map(\.uid))
            if !stale.isEmpty {
                remove(
                    stale,
                    from: mapView,
                    desiredCellByID: desiredCellByID,
                    destinationCellIDByRemovedCellID: diff.destinationCellIDByRemovedCellID,
                    animated: animateResizeTransition
                )
            }
            for cellID in diff.removedCellIDs {
                if let annotation = annotationByCellID.removeValue(forKey: cellID) {
                    annotationByUID.removeValue(forKey: annotation.uid)
                }
                cellsByID.removeValue(forKey: cellID)
            }
            if !removedUIDs.isEmpty { onRemoved(removedUIDs) }
        }

        if !diff.addedCells.isEmpty {
            let annotations = diff.addedCells.map(PhotoMapAnnotation.init)
            for (cell, annotation) in zip(diff.addedCells, annotations) {
                cellsByID[cell.cellID] = cell
                annotationByCellID[cell.cellID] = annotation
                annotationByUID[cell.uid] = annotation
            }
            mapView.addAnnotations(annotations)
            if animateResizeTransition {
                animateAddedAnnotations(
                    annotations,
                    on: mapView,
                    sourceCellByID: previousCells,
                    sourceCellIDByAddedCellID: diff.sourceCellIDByAddedCellID,
                    generation: generation
                )
            }
        }
    }

    private func remove(
        _ annotations: [PhotoMapAnnotation],
        from mapView: MKMapView,
        desiredCellByID: [PhotoLocationCellID: AggregatedCoordinate],
        destinationCellIDByRemovedCellID: [PhotoLocationCellID: PhotoLocationCellID],
        animated: Bool
    ) {
        guard animated else {
            mapView.removeAnnotations(annotations)
            return
        }

        var delayedRemoval: [PhotoMapAnnotation] = []
        var immediateRemoval: [PhotoMapAnnotation] = []
        delayedRemoval.reserveCapacity(annotations.count)
        for annotation in annotations {
            guard let view = mapView.view(for: annotation), let layer = backingLayer(for: view) else {
                immediateRemoval.append(annotation)
                continue
            }
            let destination = destinationCellIDByRemovedCellID[annotation.cellID]
                .flatMap { desiredCellByID[$0] }
                .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            let delta =
                destination.map {
                    let sourcePoint = mapView.convert(annotation.coordinate, toPointTo: mapView)
                    let destinationPoint = mapView.convert($0, toPointTo: mapView)
                    return CGPoint(x: destinationPoint.x - sourcePoint.x, y: destinationPoint.y - sourcePoint.y)
                } ?? .zero
            addTransitionAnimation(to: layer, translation: delta, entering: false)
            delayedRemoval.append(annotation)
        }
        if !immediateRemoval.isEmpty { mapView.removeAnnotations(immediateRemoval) }
        guard !delayedRemoval.isEmpty else { return }
        Task { @MainActor [weak mapView] in
            try? await Task.sleep(nanoseconds: UInt64(Self.transitionDuration * 1_000_000_000))
            mapView?.removeAnnotations(delayedRemoval)
        }
    }

    private func animateAddedAnnotations(
        _ annotations: [PhotoMapAnnotation],
        on mapView: MKMapView,
        sourceCellByID: [PhotoLocationCellID: AggregatedCoordinate],
        sourceCellIDByAddedCellID: [PhotoLocationCellID: PhotoLocationCellID],
        generation: Int
    ) {
        Task { @MainActor [weak self, weak mapView] in
            await Task.yield()
            guard let self, let mapView, generation == self.reloadGeneration else { return }
            for annotation in annotations {
                guard let view = mapView.view(for: annotation), let layer = self.backingLayer(for: view) else {
                    continue
                }
                let source = sourceCellIDByAddedCellID[annotation.cellID].flatMap { sourceCellByID[$0] }
                let delta =
                    source.map {
                        let sourcePoint = mapView.convert(
                            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude),
                            toPointTo: mapView
                        )
                        let destinationPoint = mapView.convert(annotation.coordinate, toPointTo: mapView)
                        return CGPoint(x: sourcePoint.x - destinationPoint.x, y: sourcePoint.y - destinationPoint.y)
                    } ?? .zero
                self.addTransitionAnimation(to: layer, translation: delta, entering: true)
            }
        }
    }

    private func addTransitionAnimation(to layer: CALayer, translation: CGPoint, entering: Bool) {
        let transform = CABasicAnimation(keyPath: "transform")
        let translated = CATransform3DMakeTranslation(translation.x, translation.y, 0)
        transform.fromValue = entering ? translated : CATransform3DIdentity
        transform.toValue = entering ? CATransform3DIdentity : translated

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = entering ? 0.35 : 1
        opacity.toValue = entering ? 1 : 0

        let group = CAAnimationGroup()
        group.animations = [transform, opacity]
        group.duration = Self.transitionDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.isRemovedOnCompletion = entering
        if !entering {
            group.fillMode = .forwards
        }
        layer.removeAnimation(forKey: "proton.map.cellTransition")
        layer.add(group, forKey: "proton.map.cellTransition")
    }

    private func backingLayer(for view: MKAnnotationView) -> CALayer? {
        #if canImport(UIKit)
            view.layer
        #else
            view.wantsLayer = true
            return view.layer
        #endif
    }

    private static var reduceMotionEnabled: Bool {
        #if canImport(UIKit)
            UIAccessibility.isReduceMotionEnabled
        #else
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #endif
    }
}
