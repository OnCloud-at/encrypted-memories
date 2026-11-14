import PhotosCore

/// One gate for every window and protected area in the app process.
@MainActor
public enum AppProtection {
    public static let gate = AccessGate(authenticator: DeviceOwnerAuthenticator())
}
