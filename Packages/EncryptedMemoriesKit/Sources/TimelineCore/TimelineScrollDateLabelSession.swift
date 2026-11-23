import Foundation
import PhotosCore

/// The native label of one grid host, as the shared session drives it. An adapter implements it with its own drawing
/// and geometry; the rules for text preparation and the visibility transition stay in the session.
@MainActor
public protocol TimelineScrollDateLabelDisplay: AnyObject {
    /// The text that the label shows, or nil before it got any.
    var displayedText: String? { get }
    func setText(_ text: String)
    /// Measures the current text once, so the first brisk scroll does not pay for text layout.
    func prepareTextLayout()
    /// Runs after the text and before the visibility: the horizontal slide of a platform with indicator drags.
    func applyIndicatorOffset(of presentation: TimelineScrollDateLabelController.Presentation)
    /// Shows or hides the label over `duration`; without a duration it changes at once. `changesVisibility` is false
    /// when only the fade duration changed, for example Reduce Motion during a fade.
    func setShown(_ shown: Bool, duration: TimeInterval?, changesVisibility: Bool)
    /// Runs after each presentation, because a new month can change the width.
    func presentationDidApply()
}

extension TimelineScrollDateLabelDisplay {
    /// A platform without indicator drags has no slide.
    public func applyIndicatorOffset(of presentation: TimelineScrollDateLabelController.Presentation) {}
}

/// Shared chronological-surface eligibility, content reconciliation and presentation of one grid's label. Native
/// presenters own their views and their geometry.
@MainActor
public final class TimelineScrollDateLabelSession {
    public let controller: TimelineScrollDateLabelController
    public private(set) var isEnabled = false
    /// Whether the display shows the label, after the last applied presentation.
    public private(set) var isShown = false
    private var items: [PhotoItem] = []
    private var appliedFadeDuration: TimeInterval?
    private weak var display: (any TimelineScrollDateLabelDisplay)?

    public init(controller: TimelineScrollDateLabelController) { self.controller = controller }

    /// Connects the native label: presentations and newly built months reach it from now on. `reduceMotion` is the
    /// platform's current setting.
    public func attach(_ display: any TimelineScrollDateLabelDisplay, reduceMotion: Bool) {
        self.display = display
        controller.onChange = { [weak self] presentation in self?.apply(presentation) }
        controller.onIndexInstalled = { [weak self] index in self?.prepareText(for: index) }
        controller.reduceMotion = reduceMotion
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            controller.updateContent(items, replacesList: true)
        } else {
            controller.clearContent()
        }
    }

    public func contentChanged(_ newItems: [PhotoItem], replacesList: Bool) {
        items = newItems
        guard isEnabled else { return }
        controller.updateContent(newItems, replacesList: replacesList)
    }

    public func setReduceMotion(_ reduce: Bool) { controller.reduceMotion = reduce }

    /// One viewport movement of the host. A disabled label ignores it.
    public func viewportMoved(_ movement: TimelineScrollDateLabelMovement, offsetY: Double) {
        guard isEnabled else { return }
        controller.viewportMoved(movement, offsetY: offsetY)
    }

    /// The flat index of the photo that anchors the visible area. A disabled label ignores it.
    public func setAnchor(flatIndex: Int?) {
        guard isEnabled else { return }
        controller.setAnchor(flatIndex: flatIndex)
    }

    /// Ends the label with its host: no build, hide or callback outlives it.
    public func retire() {
        controller.retire()
    }

    /// Shapes the first month once, so the first brisk scroll does not pay for text layout.
    private func prepareText(for index: TimelineScrollDateIndex) {
        guard let display, display.displayedText == nil, let first = index.month(containing: 0)?.text else { return }
        display.setText(first)
        display.prepareTextLayout()
    }

    private func apply(_ presentation: TimelineScrollDateLabelController.Presentation) {
        guard let display else { return }
        if let text = presentation.text { display.setText(text) }
        display.applyIndicatorOffset(of: presentation)
        if presentation.isVisible != isShown {
            isShown = presentation.isVisible
            // Suppression, routes and stale content hide at once; shows, linger expiry and marked jumps fade.
            display.setShown(isShown, duration: presentation.fadeDuration, changesVisibility: true)
        } else if presentation.fadeDuration != appliedFadeDuration {
            display.setShown(isShown, duration: presentation.fadeDuration, changesVisibility: false)
        }
        appliedFadeDuration = presentation.fadeDuration
        display.presentationDidApply()
    }
}
