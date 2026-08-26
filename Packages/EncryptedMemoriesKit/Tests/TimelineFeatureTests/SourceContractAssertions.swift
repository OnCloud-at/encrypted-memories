extension String {
    func containsCodeFragmentIgnoringWhitespace(_ fragment: String) -> Bool {
        filter { !$0.isWhitespace }.contains(fragment.filter { !$0.isWhitespace })
    }
}
