import Testing

@testable import PhotosCore

@Suite @MainActor struct WeakAsyncReferenceTests {
    private final class Value: Sendable {}

    @Test func publishesOneAccountToConcurrentWaiters() async {
        let reference = WeakAsyncReference<Value>()
        let value = Value()
        let first = Task { await reference.whenReady(timeout: .seconds(1)) }
        let second = Task { await reference.whenReady(timeout: .seconds(1)) }
        reference.value = value
        #expect(await first.value === value)
        #expect(await second.value === value)
    }

    @Test func cancellationAndTimeoutDoNotRetainAnAccount() async {
        let reference = WeakAsyncReference<Value>()
        let cancelled = Task { await reference.whenReady(timeout: .seconds(60)) }
        cancelled.cancel()
        #expect(await cancelled.value == nil)
        #expect(await reference.whenReady(timeout: .zero) == nil)
        var account: Value? = Value()
        reference.value = account
        weak var weakAccount = account
        account = nil
        #expect(weakAccount == nil)
        #expect(reference.value == nil)
    }
}
