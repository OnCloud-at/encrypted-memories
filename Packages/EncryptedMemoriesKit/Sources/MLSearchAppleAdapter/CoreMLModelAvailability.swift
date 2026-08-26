import CoreML
import Foundation
import MLSearchCore

/// Resolves model descriptors to compiled `.mlmodelc` resources.
/// The bundle is injectable for hosts and tests. The descriptor version controls reindexing.
public struct BundleMLModelLocator: MLModelLocator, @unchecked Sendable {
    // Bundle is not Sendable by declaration, but resource lookup is documented thread-safe.
    private let bundle: Bundle

    public init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    public func availability(for descriptor: MLModelDescriptor) -> MLModelAvailability {
        if let url = bundle.url(forResource: descriptor.identifier, withExtension: "mlmodelc") {
            return .available(url: url)
        }
        return .missing(descriptor: descriptor)
    }
}
