import PhotosCore

#if DEBUG
    /// Keeps the network of the offline UI test scenario unreachable. Debug builds only.
    ///
    /// The real path monitor of `AppleLibraryRuntimeAdapter` writes the same runtime state from its own queue. Its
    /// first path can arrive after the scenario started, for example on a loaded runner, so one write is not enough:
    /// every reachable path that arrives later is answered with the unreachable state again.
    @MainActor
    final class MobileFixtureOfflineNetwork {
        private let holdTask: Task<Void, Never>

        init(state: LibraryRuntimeState = .shared) {
            let updates = state.updates()
            Self.makeUnreachable(state)
            holdTask = Task {
                for await snapshot in updates where snapshot.network.isReachable {
                    guard !Task.isCancelled else { return }
                    Self.makeUnreachable(state)
                }
            }
        }

        deinit {
            holdTask.cancel()
        }

        private nonisolated static func makeUnreachable(_ state: LibraryRuntimeState) {
            state.update { $0.network = LibraryNetworkState(isReachable: false) }
        }
    }
#endif
