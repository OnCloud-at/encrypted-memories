import Foundation

/// An error whose own sentence the library-load screen may show under its title. Only an error that the app
/// itself words qualifies; a system or server text never does.
public protocol LibraryLoadFailureSentence: Error {
    var librarySentence: String { get }
}

/// The one builder of the library-load error screen's text. The iOS and macOS load paths both read this enum so the
/// screen reads the same on every platform.
public enum LibraryLoadFailureMessage {
    /// The sentence under the screen's title: the error's own sentence when the app words it, otherwise empty, and the
    /// screen shows the title and Try again alone. The text of a system or server error means nothing to the person.
    public static func message(for error: Error) -> String {
        (error as? any LibraryLoadFailureSentence)?.librarySentence ?? ""
    }

    /// The sentence for a session that Proton rejected: the person signs in again.
    public static var rejectedSession: String { L10n.string("auth.sign_in_again") }
}
