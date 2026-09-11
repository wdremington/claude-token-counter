import Foundation

/// Wording that has to say the same thing everywhere it appears.
enum Copy {
    /// What the dollar figures in this app actually mean.
    ///
    /// Worth repeating in several places: most individual Claude Code users are
    /// on a Max or Pro subscription and are not billed per token at all, so a
    /// confident-looking total is easy to misread as a bill.
    static let listPriceNote = """
        Anthropic first-party API list prices. This is not a bill: it does not \
        reflect Max or Pro subscriptions, Bedrock or Vertex partner rates, or \
        batch discounts. Read it as what this usage would cost at list price.
        """

    static let listPriceShort = "Anthropic API list prices — not a bill."
}
