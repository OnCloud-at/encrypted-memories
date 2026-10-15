func f(_ x: Int) {
    switch x {
    case 1:
        fallthrough
    case 2:
        print(x)
    default:
        break
    }
}
