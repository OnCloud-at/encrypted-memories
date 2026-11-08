import PhotosCore

/// Shared chronological-surface eligibility and content reconciliation. Native presenters own their views.
@MainActor
public final class TimelineScrollDateLabelSession {
    public let controller: TimelineScrollDateLabelController
    public private(set) var isEnabled = false
    private var items: [PhotoItem] = []

    public init(controller: TimelineScrollDateLabelController) { self.controller = controller }
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
}
