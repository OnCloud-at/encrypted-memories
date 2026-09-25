import AppKit
import SwiftUI

/// AppKit owns the Settings toolbar so account changes do not leave stale SwiftUI tab items.
struct MacSettingsTabs: NSViewControllerRepresentable {
    struct Tab {
        enum ID: String {
            case account, support, library, smartSearch, backup, labs, diagnostics
        }

        let id: ID
        let title: String
        let systemImage: String
        let content: AnyView

        init(id: ID, title: String, systemImage: String, @ViewBuilder content: () -> some View) {
            self.id = id
            self.title = title
            self.systemImage = systemImage
            self.content = AnyView(content())
        }
    }

    let tabs: [Tab]

    func makeNSViewController(context: Context) -> NSTabViewController {
        let controller = NSTabViewController()
        controller.tabStyle = .toolbar
        // Account content must disappear immediately when its tab is removed.
        controller.transitionOptions = []
        controller.canPropagateSelectedChildViewControllerTitle = false
        updateNSViewController(controller, context: context)
        return controller
    }

    func updateNSViewController(_ controller: NSTabViewController, context: Context) {
        for item in controller.tabViewItems
        where !tabs.contains(where: { $0.id.rawValue == item.identifier as? String }) {
            controller.removeTabViewItem(item)
        }

        for (index, tab) in tabs.enumerated() {
            let content = AnyView(tab.content.environment(\.self, context.environment))
            let item: NSTabViewItem
            if let existing = controller.tabViewItems.first(where: { $0.identifier as? String == tab.id.rawValue }) {
                item = existing
                // Keep each pane's identity and local state while forwarding current inputs and environment.
                (item.viewController as? NSHostingController<AnyView>)?.rootView = content
            } else {
                item = NSTabViewItem(viewController: NSHostingController(rootView: content))
                item.identifier = tab.id.rawValue
                controller.insertTabViewItem(item, at: index)
            }
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: tab.title)
            item.toolTip = tab.title
        }
    }
}
