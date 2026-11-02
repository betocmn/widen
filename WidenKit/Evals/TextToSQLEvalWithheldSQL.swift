import Foundation

/// SQL the grounding postprocessor withheld: generated SQL that
/// `GeneratedSQLPostprocessor.enriched` replaced with a clarification. A
/// semantic run compares it with the golden SQL for the results that expected
/// SQL, which shows what each replacement cost without changing any result's
/// status. The SQL stays in memory: a result records only that SQL was
/// withheld and how it compared.
public enum TextToSQLEvalWithheldSQL {
    /// What a semantic run does with a result's withheld SQL.
    public enum Scoring: Equatable, Sendable {
        /// Nothing to compare: the result withheld no SQL, or its case
        /// expects a clarification, where withholding the SQL was right.
        case skipped
        /// The SQL fails the guards the pipeline applies before it shows SQL:
        /// the safety validator and closed-world schema validation, after the
        /// same quote repair. Writes fail too, since nothing would release
        /// one. It is never executed.
        case rejectedByGuards
        /// The SQL to execute and compare with the golden SQL, quote-repaired
        /// when the pipeline would have repaired it.
        case compare(sql: String)
    }

    public static func scoring(
        for result: TextToSQLEvalResult,
        evalCase: TextToSQLEvalCase,
        schema: DatabaseSchema
    ) -> Scoring {
        guard evalCase.expected.decision == .sql,
            let sql = result.withheldSQL?.trimmingCharacters(in: .whitespacesAndNewlines),
            !sql.isEmpty
        else { return .skipped }
        let validation = GeneratedSQLValidator.validate(sql: sql, schema: schema)
        let candidate = validation.isValid
            ? sql
            : GeneratedSQLValidator.repairQuotedIdentifiers(sql: sql, schema: schema)
        guard let candidate, !SQLSafetyValidator.validate(candidate).kind.isWrite else {
            return .rejectedByGuards
        }
        return .compare(sql: candidate)
    }

    /// The withheld SQL's status for one execution, read in the same order
    /// as the result's own semantic status.
    public static func semanticStatus(
        for output: TextToSQLSemanticExecutionOutput
    ) -> TextToSQLSemanticStatus {
        if output.resultLimitExceeded { return .resultLimitExceeded }
        if output.goldenError != nil { return .goldenFixtureFailure }
        if output.candidateError != nil { return .candidateExecutionFailure }
        return output.comparison?.equivalent == true ? .passed : .resultMismatch
    }
}

extension TextToSQLEvalResult {
    /// Keeps the SQL the pipeline withheld, in memory, and marks the result.
    func recordingWithheldSQL(_ sql: String?) -> TextToSQLEvalResult {
        guard let sql = sql?.trimmingCharacters(in: .whitespacesAndNewlines), !sql.isEmpty else {
            return self
        }
        var copy = self
        copy.withheldSQL = sql
        copy.metrics.groundingWithheldSQL = true
        return copy
    }

    /// Records how the withheld SQL compared. `status` and `endToEndPassed`
    /// stay as they are: the result answered with its clarification.
    public func withWithheldSQLSemantic(status: TextToSQLSemanticStatus) -> TextToSQLEvalResult {
        var copy = self
        copy.metrics.withheldSQLSemanticStatus = status
        copy.metrics.withheldSQLSemanticPassed = switch status {
        case .passed:
            true
        case .resultMismatch, .candidateExecutionFailure, .resultLimitExceeded:
            false
        case .goldenFixtureFailure, .semanticEnvironmentUnavailable, .fixtureInvalid,
            .notApplicable:
            nil
        }
        return copy
    }
}

/// Counts of the SQL the grounding postprocessor withheld, over eval results.
/// They are reported only and never gate a run.
public struct TextToSQLEvalWithheldSQLSummary: Codable, Equatable, Sendable {
    /// Results whose generated SQL the postprocessor replaced with the
    /// clarification they answered with.
    public var withheldResults: Int
    /// Withheld results whose case expected SQL, so the clarification failed
    /// the decision. The others expected a clarification.
    public var expectedSQLResults: Int
    /// Withheld SQL the semantic comparison judged: compared with the golden
    /// result, or stopped by the safety or schema guards.
    public var scoredResults: Int
    /// Withheld SQL that matched the golden result.
    public var semanticPassed: Int
    /// The withheld SQL's semantic statuses, over the results that have one.
    public var semanticStatusCounts: [String: Int]

    public init(
        withheldResults: Int,
        expectedSQLResults: Int,
        scoredResults: Int,
        semanticPassed: Int,
        semanticStatusCounts: [String: Int]
    ) {
        self.withheldResults = withheldResults
        self.expectedSQLResults = expectedSQLResults
        self.scoredResults = scoredResults
        self.semanticPassed = semanticPassed
        self.semanticStatusCounts = semanticStatusCounts
    }

    /// Nil when no result withheld SQL, as in results written before it was
    /// recorded.
    public init?(results: [TextToSQLEvalResult]) {
        let withheld = results.filter { $0.metrics.groundingWithheldSQL == true }
        guard !withheld.isEmpty else { return nil }
        let judged = withheld.compactMap(\.metrics.withheldSQLSemanticPassed)
        self.init(
            withheldResults: withheld.count,
            // A withheld result answered with a clarification, so its
            // decision matches only when the case expected one.
            expectedSQLResults: withheld.filter { !$0.metrics.decisionMatches }.count,
            scoredResults: judged.count,
            semanticPassed: judged.filter { $0 }.count,
            semanticStatusCounts: TextToSQLEvalExtraCallsRows.counts(
                withheld.compactMap(\.metrics.withheldSQLSemanticStatus?.rawValue)
            )
        )
    }

    /// `| Metric | Value |` rows, with dashes for a run that withheld no SQL.
    public static func markdownRows(_ summary: Self?) -> [String] {
        typealias Rows = TextToSQLEvalExtraCallsRows
        return [
            "| SQL withheld by grounding | \(Rows.value(summary?.withheldResults)) |",
            "| Withheld SQL where SQL was expected | \(Rows.share(summary?.expectedSQLResults, of: summary?.withheldResults)) |",
            "| Withheld SQL semantic passes | \(Rows.share(summary?.semanticPassed, of: summary?.scoredResults)) |",
            "| Withheld SQL semantic statuses | \(Rows.countList(summary?.semanticStatusCounts)) |",
        ]
    }
}
