enum E {
    case a(x: Int)
}
func f(_ e: E) {
    switch e {
    case .a(x: let x):
        print(x)
    }
}
