import Foundation

/// The load and the check of one Duplicates screen, for every platform. The screen creates it once and keeps it for
/// its whole life. A screen that only goes out of sight under the list of differing copies keeps its load and check;
/// one that goes away stops them, also when it ends while that list covers it.
@MainActor
public final class ExactDuplicatesScreenLoad {
    private let model: ExactDuplicatesModel
    private var load: Task<Void, Never>?

    public init(model: ExactDuplicatesModel) {
        self.model = model
    }

    /// The screen appears. Starts the load at once, as the screen appears, unless it runs from an earlier appearance.
    public func appear() {
        guard load == nil else { return }
        let model = model
        load = Task.immediate { await model.load(checkAllGroups: true) }
    }

    /// The screen went away: stops its load and its check. The next appearance loads again.
    public func stop() {
        guard let load else { return }
        load.cancel()
        self.load = nil
        model.screenDisappeared()
    }

    isolated deinit { stop() }
}
