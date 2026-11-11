/// SafariCbBuilder is responsible for building a Safari content blocking JSON
/// from the `CompilationResult`.
enum SafariCbBuilder {
    /// Represents the result of building a content blocker.
    struct Result {
        /// Final content blocker JSON.
        let json: String

        /// The total number of Safari content blocking rules in the JSON.
        let rulesCount: Int

        /// The number of rules discarded either to `maxRules` or to `maxJsonSizeBytes`.
        let discardedRulesCount: Int
    }

    /// Builds content blocker JSON.
    ///
    /// - Parameters:
    ///   - compilationResult: Result of converting AdGuard rules to Safari CB rules.
    ///   - maxRules: Maximum number of entries in the final JSON that is allowed.
    ///   - maxJsonSizeBytes: Maximum size in bytes of the final JSON.
    ///                       Due to iOS limitations we have to limit the final result.
    /// - Returns: build result
    static func buildCbJson(
        from compilationResult: CompilationResult,
        maxRules: Int,
        maxJsonSizeBytes: Int? = nil
    ) -> Result {
        var (entries, discardedCount) = createEntries(from: compilationResult, maxRules: maxRules)

        if entries.count > maxRules {
            discardedCount += entries.count - maxRules
            entries.removeLast(entries.count - maxRules)
        }

        let (json, entriesCount) = createJSONString(
            entries: entries,
            maxJsonSizeBytes: maxJsonSizeBytes
        )

        // Some entries might have been discarded due to the size limit.
        discardedCount += entries.count - entriesCount

        return Result(
            json: json,
            rulesCount: entriesCount,
            discardedRulesCount: discardedCount
        )
    }

    /// Creates an array of rules for Safari content blocker in the correct order. Over `maxRules`,
    /// blocking groups lose rules from their ends, generic CSS first; exception groups are kept whole.
    private static func createEntries(from result: CompilationResult, maxRules: Int) -> ([BlockerEntry], Int) {
        var groups = [
            result.cssBlockingWide, result.cssBlockingGenericDomainSensitive,
            result.cssBlockingGenericHideExceptions, result.cssBlockingDomainSensitive,
            result.cssElemhideExceptions, result.urlBlocking, result.otherExceptions,
            result.important, result.importantExceptions, result.documentExceptions,
        ]
        var excess = groups.reduce(0) { $0 + $1.count } - maxRules
        var discarded = 0
        for index in [0, 1, 3, 5, 7] where excess > 0 {
            let cut = min(excess, groups[index].count)
            groups[index].removeLast(cut)
            excess -= cut
            discarded += cut
        }
        return (groups.flatMap { $0 }, discarded)
    }

    /// Serializes a list of `BlockerEntry` to JSON taking into account the size limit `maxJsonSizeBytes`.
    /// If the size limit is reached, extra rules will be discarded.
    private static func createJSONString(
        entries: [BlockerEntry],
        maxJsonSizeBytes: Int?
    ) -> (String, Int) {
        if entries.isEmpty {
            return (ConversionResult.EMPTY_RESULT_JSON, 0)
        }

        let encoder = BlockerEntryEncoder()
        let (encoded, count) = encoder.encode(entries: entries, maxJsonSizeBytes: maxJsonSizeBytes)

        // if nothing was converted due to limits, return empty result json
        if count == 0 {
            return (ConversionResult.EMPTY_RESULT_JSON, 0)
        }

        return (encoded, count)
    }
}
