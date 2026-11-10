/// Polls until `condition` holds or ten seconds pass. A `.timeLimit` cannot stop a `Task.yield` loop.
func waitUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
}
