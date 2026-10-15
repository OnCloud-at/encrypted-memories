import Foundation

class A {
    init() {}
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
