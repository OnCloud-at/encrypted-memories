import PhotosCore

extension AccountStateDamagedError: FailureClassifiable {
    public var failureCause: FailureCause { .unknown }
}

extension AccountStateReadOnlyError: FailureClassifiable {
    public var failureCause: FailureCause { .unsupported }
}

extension AccountStateInvalidChangeError: FailureClassifiable {
    public var failureCause: FailureCause { .unknown }
}
