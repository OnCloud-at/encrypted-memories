func f(_ x: Int) {
    switch x {
    case 1:
        fallthrough
    default:
        print(x)
    }
}
