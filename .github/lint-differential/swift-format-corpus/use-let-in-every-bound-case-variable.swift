enum E {
    case a(Int, Int)
}
func f(_ e: E) {
    switch e {
    case let .a(x, y):
        print(x, y)
    }
}
