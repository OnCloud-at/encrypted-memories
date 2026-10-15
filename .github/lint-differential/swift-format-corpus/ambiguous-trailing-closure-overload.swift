func f(a: () -> Void) {}
func f(b: () -> Void) {}
func g() {
    f { }
}
