import Foundation

/// Compilation result is an intermediate result object, before building final conversion result.
/// Contains blocker entries objects sorted in groups by source rule type and purpose.
struct CompilationResult {
    /// Total number of Safari rules in the result.
    var rulesCount: Int {
        cssBlockingWide.count + cssBlockingGenericDomainSensitive.count
            + cssBlockingDomainSensitive.count + cssBlockingGenericHideExceptions.count
            + cssElemhideExceptions.count + urlBlocking.count + otherExceptions.count
            + important.count + importantExceptions.count + documentExceptions.count
    }

    /// Elemhide rules (##) - wide generic rules.
    ///
    /// Example: `##.banner`
    var cssBlockingWide: [BlockerEntry] = []

    /// Elemhide rules (##) - generic domain sensitive
    ///
    /// Example: `~example.org##.banner`
    var cssBlockingGenericDomainSensitive: [BlockerEntry] = []

    /// Elemhide rules (##) with domain restrictions.
    ///
    /// Example: `example.org##.banner`.
    var cssBlockingDomainSensitive: [BlockerEntry] = []

    /// Generic hide exceptions.
    ///
    /// Example: `example.org#@#.banner`
    var cssBlockingGenericHideExceptions: [BlockerEntry] = []

    /// Elemhide exceptions (`$elemhide`)
    var cssElemhideExceptions: [BlockerEntry] = []

    /// Url blocking rules.
    var urlBlocking: [BlockerEntry] = []

    /// Other exceptions
    var otherExceptions: [BlockerEntry] = []

    /// `$important` url blocking rules.
    var important: [BlockerEntry] = []

    /// `$important` url blocking exceptions.
    var importantExceptions: [BlockerEntry] = []

    /// `$document` url blocking exceptions.
    var documentExceptions: [BlockerEntry] = []

    /// Adds a new entry with action`block`.
    mutating func addBlockTypedEntry(entry: BlockerEntry, source: Rule) {
        if source.isImportant {
            important.append(entry)
        } else {
            urlBlocking.append(entry)
        }
    }

    /// Adds a new entry with action `ignore-previous-rules`.
    mutating func addIgnorePreviousTypedEntry(entry: BlockerEntry, rule: Rule) {
        if let networkRule = rule as? NetworkRule {
            if networkRule.isSingleOption(option: .generichide) {
                cssBlockingGenericHideExceptions.append(entry)
            } else if networkRule.isSingleOption(option: .elemhide) {
                cssElemhideExceptions.append(entry)
            } else if networkRule.isImportant {
                importantExceptions.append(entry)
            } else if networkRule.isDocumentWhiteList {
                documentExceptions.append(entry)
            } else {
                otherExceptions.append(entry)
            }
        } else {
            otherExceptions.append(entry)
        }
    }
}

extension CompilationResult {
    /// a hide for one site matches the frame's own URL on document loads instead of WebKit's top-URL
    /// condition, which is checked on every load; that site's `$elemhide` exceptions gain the same copy
    mutating func anchorSiteHides() {
        cssBlockingDomainSensitive = cssBlockingDomainSensitive.map { $0.anchoredToSite ?? $0 }
        cssElemhideExceptions = cssElemhideExceptions.flatMap { entry in entry.anchoredToSite.map { [entry, $0] } ?? [entry] }
    }
}

extension BlockerEntry {
    /// a hide on several sites as one hide per site; anything else unchanged
    var perSite: [BlockerEntry] {
        guard let domains = trigger.ifDomain, domains.count > 1, trigger == Trigger(ifDomain: domains, urlFilter: ".*")
        else { return [self] }
        return domains.map { BlockerEntry(trigger: Trigger(ifDomain: [$0], urlFilter: ".*"), action: action) }
    }

    /// this entry on document loads whose own URL is on its one `if-domain`; nil for any other trigger.
    /// `*example.org` also covers subdomains
    var anchoredToSite: BlockerEntry? {
        guard let domain = trigger.ifDomain?.first, trigger == Trigger(ifDomain: [domain], urlFilter: ".*") else { return nil }
        let wide = domain.hasPrefix("*")
        let host = wide ? domain.dropFirst() : Substring(domain)
        guard !host.isEmpty, host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) })
        else { return nil }
        let filter = "^[^:]+://+" + (wide ? #"([^:/]+\.)?"# : "") + host.replacingOccurrences(of: ".", with: #"\."#) + "[/:?#]"
        return BlockerEntry(trigger: Trigger(urlFilter: filter, resourceType: ["document"]), action: action)
    }
}
