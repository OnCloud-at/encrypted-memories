func f(_ c: () -> Void) {}
func g() {
    f() { }
}
