/// Polls until `condition` holds or `timeout` passes. A `.timeLimit` cannot stop a `Task.yield` loop.
func waitUntil(timeout: Duration = .seconds(10), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
}
