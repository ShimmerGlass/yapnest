extension String {
    /// Without the empty lines some bots put around their text, which would
    /// show as blank space in a bubble or leave a banner's first line empty.
    /// Only for display: the stored message keeps its body.
    public var trimmingBlankEdgeLines: String {
        let lines = Substring(self).split(separator: "\n", omittingEmptySubsequences: false)
        // Found by index: dropping lines one at a time from the front is
        // quadratic in a body made of blank lines.
        guard let first = lines.firstIndex(where: { !$0.allSatisfy(\.isWhitespace) }),
              let last = lines.lastIndex(where: { !$0.allSatisfy(\.isWhitespace) }) else { return "" }
        return lines[first...last].joined(separator: "\n")
    }
}
