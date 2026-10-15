func f(a: () -> Void, b: () -> Void) {}
func g() {
    f { } b: { }
}
