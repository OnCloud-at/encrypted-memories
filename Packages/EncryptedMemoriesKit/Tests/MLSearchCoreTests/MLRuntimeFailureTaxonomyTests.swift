import Foundation
import Testing

@testable import MLSearchCore

@Suite struct MLRuntimeFailureTaxonomyTests {
    @Test func permanentCategoriesCannotRetry() {
        let categories: [MLRuntimeFailureCategory] = [
            .missingModel,
            .incompatibleModel,
            .invalidOutputSchema,
            .invalidStaticInputContract,
        ]
        for category in categories {
            let failure = MLRuntimeFailure(category: category)
            #expect(failure.disposition == .permanent)
            #expect(failure.isPermanent)
            #expect(!failure.isRetryable)
        }
    }

    @Test func transientAndUnknownCategoriesRemainRetryable() {
        let categories: [MLRuntimeFailureCategory] = [
            .network,
            .temporaryResource,
            .retryableRuntimeState,
            .unknown,
        ]
        for category in categories {
            let failure = MLRuntimeFailure(category: category)
            #expect(failure.isRetryable)
        }
        #expect(MLRuntimeFailure(category: .unknown).disposition == .unknown)
    }

    @Test func typedDispositionDoesNotNeedPersistence() {
        let failure = MLRuntimeFailure(
            category: .unknown,
            debugDescription: "unclassified runtime error"
        )
        #expect(failure.category == .unknown)
        #expect(failure.disposition == .unknown)
        #expect(failure.isRetryable)
    }

    @Test func categoryIsTheAuthoritativeDisposition() {
        for category in MLRuntimeFailureCategory.allCasesForTesting {
            #expect(MLRuntimeFailure(category: category).disposition == category.disposition)
        }
    }
}

private extension MLRuntimeFailureCategory {
    static let allCasesForTesting: [Self] = [
        .missingModel,
        .incompatibleModel,
        .invalidOutputSchema,
        .invalidStaticInputContract,
        .network,
        .temporaryResource,
        .retryableRuntimeState,
        .unknown,
    ]
}
