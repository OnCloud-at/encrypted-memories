#if canImport(UIKit)
    import GridCore
    import PhotosCore
    import UIKit

    /// Owns the native accessibility projection for the grid surface.
    ///
    /// The Metal surface stays the hit-testing and gesture owner. This provider exposes only the current
    /// `GridFramePlan.visibleSlots`, in engine order, through stable UID-keyed `UIAccessibilityElement` instances.
    @MainActor
    final class UIKitTimelineGridAccessibilityProvider {
        weak var container: UIView?
        private var elementsByUID: [PhotoUID: UIKitTimelineGridAccessibilityElement] = [:]
        private(set) var elements: [UIKitTimelineGridAccessibilityElement] = []
        private var invalidationScheduled = false

        var onOpen: ((PhotoItem) -> Void)?
        var onToggleSelection: ((PhotoItem) -> Void)?

        init(container: UIView) {
            self.container = container
        }

        /// Converts a grid viewport rect through the drawable viewport. The rect is already relative to the
        /// viewport, so using the scroll view as the source would subtract its content offset a second time.
        static func frameInContainer(
            for slot: GridSlot,
            viewport: UIView,
            container: UIView
        ) -> CGRect {
            viewport.convert(slot.viewportRect, to: container)
        }

        func invalidate() {
            guard !invalidationScheduled else { return }
            invalidationScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.invalidationScheduled = false
                self.rebuildFromHost()
            }
        }

        func rebuildFromHost() {
            guard let host = container as? UIKitTimelineGridHostView,
                host.window != nil,
                host.framePump.isActive,
                let plan = host.accessibilityFramePlan()
            else {
                replaceElements([])
                return
            }

            rebuild(
                items: host.accessibilityItems,
                visibleSlots: plan.visibleSlots,
                selectedUIDs: host.selectedUIDs,
                selectionMode: host.selectionMode,
                frameForSlot: { [weak host] slot in
                    guard let host else { return .zero }
                    return Self.frameInContainer(for: slot, viewport: host.metalView, container: host)
                }
            )
        }

        /// Rebuilds the visible projection while retaining an element for every UID that remains visible.
        /// Tests use this seam without constructing Metal or a window-backed host.
        func rebuild(
            items: [PhotoItem],
            visibleSlots: [GridSlot],
            selectedUIDs: Set<PhotoUID>,
            selectionMode: Bool,
            frameForSlot: (GridSlot) -> CGRect
        ) {
            guard let container else {
                replaceElements([])
                return
            }

            var nextElements: [UIKitTimelineGridAccessibilityElement] = []
            var nextByUID: [PhotoUID: UIKitTimelineGridAccessibilityElement] = [:]
            nextElements.reserveCapacity(visibleSlots.count)

            for slot in visibleSlots {
                guard items.indices.contains(slot.index) else { continue }
                let item = items[slot.index]
                let element =
                    elementsByUID[item.uid]
                    ?? UIKitTimelineGridAccessibilityElement(container: container, uid: item.uid)
                element.update(
                    item: item,
                    selected: selectedUIDs.contains(item.uid),
                    selectionMode: selectionMode,
                    position: slot.index + 1,
                    total: items.count,
                    frame: frameForSlot(slot),
                    onOpen: { [weak self] item in self?.onOpen?(item) },
                    onToggleSelection: { [weak self] item in self?.onToggleSelection?(item) }
                )
                nextElements.append(element)
                nextByUID[item.uid] = element
            }

            elementsByUID = nextByUID
            replaceElements(nextElements)
        }

        private func replaceElements(_ next: [UIKitTimelineGridAccessibilityElement]) {
            elements = next
            container?.accessibilityElements = next
        }
    }

    /// A single native accessibility node for one visible grid item.
    @MainActor
    final class UIKitTimelineGridAccessibilityElement: UIAccessibilityElement {
        let uid: PhotoUID
        private var activateAction: (() -> Bool)?
        private static let labelFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter
        }()

        init(container: UIView, uid: PhotoUID) {
            self.uid = uid
            super.init(accessibilityContainer: container)
        }

        func update(
            item: PhotoItem,
            selected: Bool,
            selectionMode: Bool,
            position: Int,
            total: Int,
            frame: CGRect,
            onOpen: @escaping (PhotoItem) -> Void,
            onToggleSelection: @escaping (PhotoItem) -> Void
        ) {
            accessibilityFrameInContainerSpace = frame
            let kind = L10n.string(item.isVideo ? "a11y.video" : "a11y.photo")
            accessibilityLabel = "\(kind), \(Self.labelFormatter.string(from: item.captureTime))"
            accessibilityValue = L10n.string("a11y.grid.position \(position) \(total)")
            accessibilityHint = L10n.string(selectionMode ? "a11y.select_photo_hint" : "a11y.open_photo_hint")
            var traits: UIAccessibilityTraits = [.image, .button]
            if selected { traits.insert(.selected) }
            accessibilityTraits = traits
            activateAction = {
                if selectionMode {
                    onToggleSelection(item)
                } else {
                    onOpen(item)
                }
                return true
            }
        }

        override func accessibilityActivate() -> Bool {
            activateAction?() ?? false
        }
    }
#endif
