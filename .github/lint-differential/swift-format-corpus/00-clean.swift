import Foundation

/// A small clean type.
struct Counter {
    var value: Int

    func next() -> Int {
        value + 1
    }
}
