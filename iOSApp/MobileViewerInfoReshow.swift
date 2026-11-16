/// Keeps Info as the user left it when an iPhone's width class changes on iOS 26.
///
/// On iOS 26 the system changes the viewer's Info state itself when the width class changes. A rotation to landscape
/// closes a shown sheet without showing the column, and a rotation back to portrait closes Info about half a second
/// after the width change. After Info was shown in landscape once, a later rotation to landscape can open Info again
/// although the user closed it. iOS 27 moves Info into the form of the new width itself.
///
/// The rule records the changes the user makes while no width change is pending. A width change stays pending until its
/// settle time: the rule ignores the Info changes that arrive meanwhile and puts Info back to the user's state 250 ms
/// after the latest of these events. At its settle time the width change ends, and Info goes back to the user's state
/// if it still differs. iPad keeps the system behavior: on iPadOS 26 a sheet shown in a compact window can raise a
/// UIKit exception when the window becomes regular, so the rule never follows a width change there.
struct MobileViewerInfoReshow {
    let isPhone: Bool
    /// Info as the user left it.
    private(set) var intended: Bool
    private(set) var widthChangePending = false
    /// Counts the events, so that only the check of the latest event decides.
    private(set) var generation = 0
    /// Counts the width changes, so that only the settle time of the latest width change ends it.
    private(set) var widthChanges = 0

    init(isPhone: Bool, showInfo: Bool) {
        self.isPhone = isPhone
        intended = showInfo
    }

    /// Returns the generation that a later check must present, or nil when the rule does not follow the change.
    mutating func widthClassDidChange() -> Int? {
        guard isPhone else { return nil }
        widthChangePending = true
        widthChanges &+= 1
        generation &+= 1
        return generation
    }

    /// Returns the generation that a later check must present, or nil for the user's own change.
    mutating func showInfoDidChange(to showInfo: Bool) -> Int? {
        guard widthChangePending else {
            intended = showInfo
            return nil
        }
        generation &+= 1
        return generation
    }

    /// The value `showInfo` must take while a width change is pending, or nil. Only the check of the latest event
    /// decides.
    func correction(checking checkGeneration: Int, showInfo: Bool) -> Bool? {
        guard checkGeneration == generation, widthChangePending, showInfo != intended else { return nil }
        return intended
    }

    /// Ends the latest width change at its settle time and returns the value `showInfo` must take, or nil.
    mutating func widthChangeDidSettle(_ widthChange: Int, showInfo: Bool) -> Bool? {
        guard widthChange == widthChanges, widthChangePending else { return nil }
        widthChangePending = false
        return showInfo == intended ? nil : intended
    }
}
