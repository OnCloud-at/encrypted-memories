import SwiftUI

extension EnvironmentValues {
    /// The edge where iPhone Duo places its vertical bar in this context (`toolbarVerticalEdge`), or nil where the
    /// system never uses one: on the Mac, on other devices, in size classes that keep horizontal bars, and before
    /// iOS 27.1. The iOS 27.0 SDK has no such value, so an app built with Xcode 27.0 always reads nil.
    public var verticalBarEdge: HorizontalEdge? {
        #if os(iOS) && canImport(SwiftUI, _version: 8.0.85)
            if #available(iOS 27.1, *) {
                return toolbarVerticalEdge
            }
        #endif
        return nil
    }
}

extension View {
    /// A text-titled toolbar item that can join the vertical bar. The system shows only items with a symbol there,
    /// so the item carries a symbol and a title; where no vertical bar exists, it keeps its familiar text look.
    public func textBarItem() -> some View {
        modifier(TextBarItem())
    }
}

private struct TextBarItem: ViewModifier {
    @Environment(\.verticalBarEdge) private var verticalBarEdge

    func body(content: Content) -> some View {
        if verticalBarEdge == nil {
            content.labelStyle(.titleOnly)
        } else {
            content
        }
    }
}
