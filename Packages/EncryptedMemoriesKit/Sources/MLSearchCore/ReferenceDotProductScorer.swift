import Foundation
import PhotosCore

/// Portable scalar scorer used to verify optimized implementations.
/// `AccelerateVectorScorer` must produce the same values within floating-point tolerance.
/// Normalized embeddings use their dot product as cosine similarity.
public struct ReferenceDotProductScorer: MLVectorScorer {
    public init() {}

    public func score(block: MLVectorBlock, query: ContiguousArray<Float32>, into scores: inout [Float32]) {
        let dimension = block.dimension
        block.withUnsafeStorage { matrix in
            query.withUnsafeBufferPointer { q in
                for row in 0..<block.count {
                    var sum: Float32 = 0
                    let base = row * dimension
                    for i in 0..<dimension {
                        sum += matrix[base + i] * q[i]
                    }
                    scores[row] = sum
                }
            }
        }
    }
}
