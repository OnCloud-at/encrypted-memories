import Foundation
import PhotosCore

/// What the viewer knows about the originals of edited photos, and which version it shows. Platform-neutral.
public struct EditedPhotoOriginalState: Equatable, Sendable {
    private var originals: [PhotoUID: PhotoItem] = [:]
    private var showingOriginalOf: PhotoUID?

    public init() {}

    public func canShowOriginal(of base: PhotoUID) -> Bool { originals[base] != nil }

    public func isShowingOriginal(of base: PhotoUID) -> Bool {
        showingOriginalOf == base && originals[base] != nil
    }

    /// The item the viewer displays for the page of `base`.
    public func displayed(_ base: PhotoItem) -> PhotoItem {
        guard isShowingOriginal(of: base.uid), let original = originals[base.uid] else { return base }
        return original
    }

    /// A found original stays for the viewer's lifetime, so the control appears at most once and never goes away.
    public mutating func record(_ original: PhotoItem, of base: PhotoUID) {
        if originals[base] == nil { originals[base] = original }
    }

    /// Switches the page of `base` between the edited version and the original.
    public mutating func toggle(_ base: PhotoUID) {
        guard originals[base] != nil else { return }
        showingOriginalOf = showingOriginalOf == base ? nil : base
    }

    /// Another page shows its edited version again.
    public mutating func pageChanged(to base: PhotoUID?) {
        if showingOriginalOf != base { showingOriginalOf = nil }
    }
}

/// Asks the backend for the original of the settled page, sparingly.
///
/// A photo must stay the settled page for `dwell` before the ask starts, so paging through photos sends nothing. The
/// ask is cancelled when the person pages on. Each photo is asked at most once per viewer; the backend keeps the
/// answer for the session. Nothing is asked while the app is not active in the foreground or the network is
/// constrained.
@MainActor
public final class EditedPhotoOriginalLookup {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    public static let dwell: Duration = .seconds(1)

    private let sleep: Sleep
    private let admits: @Sendable () -> Bool
    private var answered: Set<PhotoUID> = []
    private(set) var pending: Task<Void, Never>?

    public init(
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        admits: @escaping @Sendable () -> Bool = {
            EditedPhotoOriginalLookup.admits(LibraryRuntimeState.shared.snapshot())
        }
    ) {
        self.sleep = sleep
        self.admits = admits
    }

    /// The ask is a low-priority extra: only while the app is active in the foreground on an unconstrained network.
    public nonisolated static func admits(_ snapshot: LibraryRuntimeSnapshot) -> Bool {
        snapshot.executionOpportunity == .foregroundActive && snapshot.network.isReachable
            && !snapshot.network.isConstrained
    }

    /// Call whenever the settled page changes. `found` receives the page's item and its original. Without a provider,
    /// for example for a photo that is not in Proton yet, nothing is asked.
    public func settled(
        on item: PhotoItem?, provider: (any EditedPhotoOriginalProviding)?,
        found: @escaping @MainActor (PhotoItem, PhotoItem) -> Void
    ) {
        cancel()
        guard let item, let provider, item.mayHaveEditedOriginal, !answered.contains(item.uid) else {
            return
        }
        pending = Task { [sleep, admits] in
            do { try await sleep(Self.dwell) } catch { return }
            guard !Task.isCancelled, admits() else { return }
            let original = try? await provider.editedOriginal(of: item)
            guard !Task.isCancelled else { return }
            self.answered.insert(item.uid)
            if let original { found(item, original) }
        }
    }

    public func cancel() {
        pending?.cancel()
        pending = nil
    }
}
