import PhotosCore

extension AccountStateDamagedError: FailureClassifiable {
    public var failureCause: FailureCause { .unknown }
}

extension AccountStateReadOnlyError: FailureClassifiable {
    // A newer document format needs an app update before this version can write it.
    public var failureCause: FailureCause { .userDecision }
}

extension AccountStateInvalidChangeError: FailureClassifiable {
    public var failureCause: FailureCause { .permanent }
}
