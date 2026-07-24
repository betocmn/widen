import Foundation

public enum SchemaToolAgentPlanConsistencyDecision: String, Codable, Equatable, Sendable {
    case notEvaluated
    case consistent
    case divergent
}

public struct SchemaToolAgentPlanConsistencyResult: Equatable, Sendable {
    public var decision: SchemaToolAgentPlanConsistencyDecision
    public var reason: String
    public var divergences: [String]

    public init(
        decision: SchemaToolAgentPlanConsistencyDecision,
        reason: String,
        divergences: [String] = []
    ) {
        self.decision = decision
        self.reason = reason
        self.divergences = divergences
    }
}

/// The structured terminal query-plan contract (PR 57 option 1).
///
/// Every field is optional at decode time; a section participates in
/// consistency validation only when it is non-empty. Decoding is
/// all-or-nothing: any unknown key, wrong type, or exceeded bound makes the
/// whole plan non-conforming, and non-conforming plans must fall back to the
/// prose diagnostics summary, never to an agent failure.
public struct SchemaToolAgentStructuredQueryPlan: Equatable, Sendable {
    public struct Join: Equatable, Sendable {
        public var table: String
        public var role: String

        public init(table: String, role: String) {
            self.table = table
            self.role = role
        }
    }

    public struct Projection: Equatable, Sendable {
        public var expression: String
        public var alias: String

        public init(expression: String, alias: String = "") {
            self.expression = expression
            self.alias = alias
        }
    }

    public struct Aggregation: Equatable, Sendable {
        public var function: String
        public var column: String
        public var alias: String

        public init(function: String, column: String = "", alias: String) {
            self.function = function
            self.column = column
            self.alias = alias
        }
    }

    public var grain: String
    public var joins: [Join]
    public var filters: [String]
    public var projection: [Projection]
    public var aggregation: [Aggregation]
    public var grouping: [String]
    public var ordering: [String]
    public var limit: Int?
    public var dateAnchors: [String]

    public init(
        grain: String = "",
        joins: [Join] = [],
        filters: [String] = [],
        projection: [Projection] = [],
        aggregation: [Aggregation] = [],
        grouping: [String] = [],
        ordering: [String] = [],
        limit: Int? = nil,
        dateAnchors: [String] = []
    ) {
        self.grain = grain
        self.joins = joins
        self.filters = filters
        self.projection = projection
        self.aggregation = aggregation
        self.grouping = grouping
        self.ordering = ordering
        self.limit = limit
        self.dateAnchors = dateAnchors
    }

    public var isEmpty: Bool {
        grain.isEmpty && joins.isEmpty && filters.isEmpty && projection.isEmpty
            && aggregation.isEmpty && grouping.isEmpty && ordering.isEmpty
            && limit == nil && dateAnchors.isEmpty
    }

    /// Populated section labels in the canonical diagnostics order.
    public var sectionLabels: [String] {
        var labels: [String] = []
        if !grain.isEmpty { labels.append("grain") }
        if !joins.isEmpty { labels.append("joins") }
        if !filters.isEmpty { labels.append("filters") }
        if !projection.isEmpty { labels.append("projection") }
        if !aggregation.isEmpty { labels.append("aggregation") }
        if !grouping.isEmpty { labels.append("grouping") }
        if !ordering.isEmpty { labels.append("ordering") }
        if limit != nil { labels.append("limit") }
        if !dateAnchors.isEmpty { labels.append("date anchors") }
        return labels
    }

    static let maximumTextLength = 200
    static let maximumAliasLength = 120
    static let maximumFunctionLength = 40
    static let maximumSectionEntries = 16
    static let maximumLimitValue = 100_000

    /// Decodes a structured plan from the terminal tool's `query_plan` object.
    /// Returns nil for anything that does not fit the contract.
    public static func decode(from value: JSONValue) -> SchemaToolAgentStructuredQueryPlan? {
        guard let object = value.objectValue else { return nil }
        let allowed: Set<String> = [
            "grain", "joins", "filters", "projection", "aggregation",
            "grouping", "ordering", "limit", "date_anchors",
        ]
        guard Set(object.keys).isSubset(of: allowed) else { return nil }

        guard
            let grain = boundedText(object["grain"], fallback: ""),
            let filters = boundedTextArray(object["filters"]),
            let grouping = boundedTextArray(object["grouping"]),
            let ordering = boundedTextArray(object["ordering"]),
            let dateAnchors = boundedTextArray(object["date_anchors"]),
            let joins = decodeJoins(object["joins"]),
            let projection = decodeProjection(object["projection"]),
            let aggregation = decodeAggregation(object["aggregation"]),
            let limit = decodeLimit(object["limit"])
        else { return nil }

        let plan = SchemaToolAgentStructuredQueryPlan(
            grain: grain,
            joins: joins,
            filters: filters,
            projection: projection,
            aggregation: aggregation,
            grouping: grouping,
            ordering: ordering,
            limit: limit,
            dateAnchors: dateAnchors
        )
        return plan.isEmpty ? nil : plan
    }

    private static func boundedText(
        _ value: JSONValue?,
        fallback: String?,
        maximumLength: Int = maximumTextLength
    ) -> String? {
        guard let value else { return fallback }
        guard let text = value.stringValue, text.count <= maximumLength else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func boundedTextArray(_ value: JSONValue?) -> [String]? {
        guard let value else { return [] }
        guard let array = value.arrayValue, array.count <= maximumSectionEntries else {
            return nil
        }
        var entries: [String] = []
        for element in array {
            guard let text = boundedText(element, fallback: nil), !text.isEmpty else {
                return nil
            }
            entries.append(text)
        }
        return entries
    }

    private static func decodeJoins(_ value: JSONValue?) -> [Join]? {
        guard let value else { return [] }
        guard let array = value.arrayValue, array.count <= maximumSectionEntries else {
            return nil
        }
        var joins: [Join] = []
        for element in array {
            guard let object = element.objectValue,
                Set(object.keys).isSubset(of: ["table", "role"]),
                let table = boundedText(object["table"], fallback: nil), !table.isEmpty,
                let role = boundedText(object["role"], fallback: "")
            else { return nil }
            joins.append(Join(table: table, role: role))
        }
        return joins
    }

    private static func decodeProjection(_ value: JSONValue?) -> [Projection]? {
        guard let value else { return [] }
        guard let array = value.arrayValue, array.count <= maximumSectionEntries else {
            return nil
        }
        var projection: [Projection] = []
        for element in array {
            guard let object = element.objectValue,
                Set(object.keys).isSubset(of: ["expression", "alias"]),
                let expression = boundedText(object["expression"], fallback: nil),
                !expression.isEmpty,
                let alias = boundedText(
                    object["alias"], fallback: "", maximumLength: maximumAliasLength
                )
            else { return nil }
            projection.append(Projection(expression: expression, alias: alias))
        }
        return projection
    }

    private static func decodeAggregation(_ value: JSONValue?) -> [Aggregation]? {
        guard let value else { return [] }
        guard let array = value.arrayValue, array.count <= maximumSectionEntries else {
            return nil
        }
        var aggregation: [Aggregation] = []
        for element in array {
            guard let object = element.objectValue,
                Set(object.keys).isSubset(of: ["function", "column", "alias"]),
                let function = boundedText(
                    object["function"], fallback: nil, maximumLength: maximumFunctionLength
                ),
                !function.isEmpty,
                let column = boundedText(object["column"], fallback: ""),
                let alias = boundedText(
                    object["alias"], fallback: nil, maximumLength: maximumAliasLength
                ),
                !alias.isEmpty
            else { return nil }
            aggregation.append(Aggregation(function: function, column: column, alias: alias))
        }
        return aggregation
    }

    private static func decodeLimit(_ value: JSONValue?) -> Int?? {
        guard let value else { return .some(nil) }
        guard let limit = value.intValue, (1...maximumLimitValue).contains(limit) else {
            return nil
        }
        return .some(limit)
    }
}

/// Deterministic consistency validation of terminal SQL against the model's
/// own structured query plan (PR 57 option 1: plan-validate-and-repair).
///
/// Every rule compares two artifacts the model authored in the same terminal
/// call, so a divergence is always model drift, never a natural-language
/// judgment. Rules fire only for populated plan sections, and only checks
/// that are deterministic on tokenized SQL are performed — free-form prose
/// sections (grain, filters, date anchors) are contract fields for the
/// model's own discipline and diagnostics, not validation inputs. This must
/// not grow into a semantic validator: per `docs/refactoring-plan.md`, Widen
/// deliberately avoids a hardcoded natural-language parser and SQL
/// conformance engine.
public enum SchemaToolAgentPlanConsistencyPolicy {
    public static func evaluate(
        sql rawSQL: String,
        plan: SchemaToolAgentStructuredQueryPlan,
        inspectedTableNames: Set<String>
    ) -> SchemaToolAgentPlanConsistencyResult {
        let sql = SQLShape.strippedOfComments(rawSQL)
        let cteNames = SQLShape.commonTableExpressionNames(in: sql)
        var divergences: [String] = []

        let sqlOutputNames = SQLShape.topLevelOutputNames(in: sql)
        let planOutputNames = planOutputNames(for: plan)
        if !planOutputNames.isEmpty, !sqlOutputNames.isEmpty {
            let missingFromSQL = planOutputNames.filter { !sqlOutputNames.contains($0) }
            if !missingFromSQL.isEmpty {
                divergences.append(
                    "plan projects \(missingFromSQL.joined(separator: ", ")) but the SQL select list does not"
                )
            }
            let missingFromPlan = sqlOutputNames.filter { !planOutputNames.contains($0) }
            if !missingFromPlan.isEmpty {
                divergences.append(
                    "the SQL selects \(missingFromPlan.joined(separator: ", ")) but the plan projection does not list them"
                )
            }
        }

        for aggregation in plan.aggregation {
            guard
                let function = SQLShape.leadingIdentifierToken(
                    in: normalizedIdentifier(aggregation.function)
                )
            else { continue }
            if !SQLShape.containsFunctionCall(named: function, in: sql) {
                divergences.append(
                    "plan aggregation \(function)(...) AS \(normalizedIdentifier(aggregation.alias)) has no matching \(function)( call in the SQL"
                )
            }
        }

        for join in plan.joins {
            // Models sometimes write a whole join description or an "x AS
            // alias" phrase into the table field; the leading qualified
            // identifier is the table under validation.
            guard
                let table = SQLShape.leadingQualifiedIdentifier(
                    in: normalizedIdentifier(join.table)
                )
            else { continue }
            if !SQLShape.referencesIdentifier(table, in: sql) {
                divergences.append("plan join table \(table) is not referenced in the SQL")
            }
            if !inspectedTableNames.isEmpty,
                !cteNames.contains(table),
                !isInspected(table, in: inspectedTableNames)
            {
                divergences.append("plan join table \(table) was not inspected with schema tools")
            }
        }

        if !plan.grouping.isEmpty, !SQLShape.containsTopLevelKeyword("group by", in: sql) {
            divergences.append("plan declares grouping but the SQL has no top-level GROUP BY")
        }
        if !plan.ordering.isEmpty, !SQLShape.containsTopLevelKeyword("order by", in: sql) {
            divergences.append("plan declares ordering but the SQL has no top-level ORDER BY")
        }
        if let limit = plan.limit {
            if let sqlLimit = SQLShape.topLevelLimitValue(in: sql) {
                if sqlLimit != limit {
                    divergences.append("plan limit \(limit) does not match SQL LIMIT \(sqlLimit)")
                }
            } else {
                divergences.append("plan declares limit \(limit) but the SQL has no top-level LIMIT")
            }
        }

        guard divergences.isEmpty else {
            return SchemaToolAgentPlanConsistencyResult(
                decision: .divergent,
                reason: divergences[0],
                divergences: divergences
            )
        }
        return SchemaToolAgentPlanConsistencyResult(
            decision: .consistent,
            reason: "terminal SQL matches the submitted structured plan"
        )
    }

    /// The output-column names the plan promises, from projection aliases (or
    /// the expression's own name when unaliased) plus aggregation aliases.
    private static func planOutputNames(for plan: SchemaToolAgentStructuredQueryPlan) -> [String] {
        var names: [String] = []
        for projection in plan.projection {
            let alias = normalizedIdentifier(projection.alias)
            if !alias.isEmpty {
                names.append(alias)
                continue
            }
            let expressionName = SQLShape.outputName(forSelectExpression: projection.expression)
            if !expressionName.isEmpty {
                names.append(expressionName)
            }
        }
        for aggregation in plan.aggregation {
            let alias = normalizedIdentifier(aggregation.alias)
            if !alias.isEmpty {
                names.append(alias)
            }
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private static func isInspected(_ table: String, in inspectedTableNames: Set<String>) -> Bool {
        if inspectedTableNames.contains(table) { return true }
        if let unqualified = table.split(separator: ".").last.map(String.init),
            inspectedTableNames.contains(unqualified)
        {
            return true
        }
        return inspectedTableNames.contains { $0.split(separator: ".").last.map(String.init) == table }
    }

    /// Identifiers are compared case-insensitively with quotes stripped. The
    /// plan and SQL are authored together in one terminal call, so folding
    /// case never conflates distinct schema objects in practice, and it keeps
    /// the rules deterministic for quoted and unquoted spellings alike.
    static func normalizedIdentifier(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
            .lowercased()
    }

    enum SQLShape {
        /// Output-column names of the first top-level SELECT list: the alias
        /// after a top-level AS, the last dotted path component for a plain
        /// column reference, or the function name for an unaliased call —
        /// mirroring PostgreSQL's default result-column naming.
        static func topLevelOutputNames(in sql: String) -> [String] {
            topLevelSelectExpressions(in: sql).compactMap { expression in
                let name = outputName(forSelectExpression: expression)
                return name.isEmpty ? nil : name
            }
        }

        static func outputName(forSelectExpression expression: String) -> String {
            var trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
            trimmed = strippedOfDistinctOnPrefix(trimmed)
            if let match = trimmed.range(
                of: #"^(distinct|all)\s+"#,
                options: [.regularExpression, .caseInsensitive]
            ) {
                trimmed = String(trimmed[match.upperBound...])
            }
            guard !trimmed.isEmpty, trimmed != "*" else { return "" }
            if let aliasRange = lastTopLevelAliasRange(in: trimmed) {
                return normalizedIdentifier(String(trimmed[aliasRange]))
            }
            if let bareAlias = trailingBareAlias(in: trimmed) {
                return bareAlias
            }
            let normalized = normalizedIdentifier(trimmed)
            if let functionName = leadingFunctionName(in: normalized) {
                return functionName
            }
            guard isPlainColumnPath(normalized) else { return "" }
            return normalized.split(separator: ".").last.map(String.init) ?? ""
        }

        /// PostgreSQL allows `SELECT expr alias` without AS. A trailing
        /// identifier separated by top-level whitespace is that bare alias
        /// when the character before the whitespace can end an operand and
        /// the token is not a keyword that legally trails an expression.
        private static func trailingBareAlias(in expression: String) -> String? {
            var depth = 0
            var quote: Character?
            var index = expression.startIndex
            var lastWhitespaceEnd: String.Index?
            var lastSignificantBeforeWhitespace: Character?
            var pendingSignificant: Character?
            while index < expression.endIndex {
                let character = expression[index]
                if let activeQuote = quote {
                    if character == activeQuote { quote = nil }
                    pendingSignificant = character
                    index = expression.index(after: index)
                    continue
                }
                switch character {
                case "'", "\"":
                    quote = character
                    pendingSignificant = character
                case "(":
                    depth += 1
                    pendingSignificant = character
                case ")":
                    depth = max(0, depth - 1)
                    pendingSignificant = character
                default:
                    if depth == 0, character == " " || character == "\n" || character == "\t" {
                        var end = expression.index(after: index)
                        while end < expression.endIndex,
                            expression[end] == " " || expression[end] == "\n"
                                || expression[end] == "\t"
                        {
                            end = expression.index(after: end)
                        }
                        lastWhitespaceEnd = end
                        lastSignificantBeforeWhitespace = pendingSignificant
                        index = end
                        continue
                    }
                    pendingSignificant = character
                }
                index = expression.index(after: index)
            }
            guard depth == 0, quote == nil,
                let tokenStart = lastWhitespaceEnd, tokenStart < expression.endIndex,
                let before = lastSignificantBeforeWhitespace,
                before.isLetter || before.isNumber || before == "_" || before == ")"
                    || before == "]" || before == "\""
            else { return nil }
            let token = String(expression[tokenStart...])
            guard
                token.range(
                    of: #"^("[^"]+"|[a-zA-Z_][a-zA-Z0-9_]*)$"#,
                    options: .regularExpression
                ) != nil
            else { return nil }
            let normalized = normalizedIdentifier(token)
            let excluded: Set<String> = [
                "null", "true", "false", "end", "asc", "desc", "unknown", "default", "from",
            ]
            guard !excluded.contains(normalized) else { return nil }
            return normalized
        }

        private static func strippedOfDistinctOnPrefix(_ expression: String) -> String {
            guard
                let match = expression.range(
                    of: #"^distinct\s+on\s*\("#,
                    options: [.regularExpression, .caseInsensitive]
                )
            else { return expression }
            var depth = 1
            var quote: Character?
            var index = match.upperBound
            while index < expression.endIndex, depth > 0 {
                let character = expression[index]
                if let activeQuote = quote {
                    if character == activeQuote { quote = nil }
                } else {
                    switch character {
                    case "'", "\"": quote = character
                    case "(": depth += 1
                    case ")": depth -= 1
                    default: break
                    }
                }
                index = expression.index(after: index)
            }
            guard depth == 0 else { return expression }
            return String(expression[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Removes `--` line comments and nested `/* */` block comments while
        /// preserving string literals and quoted identifiers, so comment text
        /// can never corrupt quote/depth tracking or match clause keywords.
        static func strippedOfComments(_ sql: String) -> String {
            var output = ""
            output.reserveCapacity(sql.count)
            var index = sql.startIndex
            var quote: Character?
            var blockDepth = 0
            while index < sql.endIndex {
                let character = sql[index]
                let next = sql.index(after: index) < sql.endIndex
                    ? sql[sql.index(after: index)]
                    : nil
                if blockDepth > 0 {
                    if character == "*", next == "/" {
                        blockDepth -= 1
                        index = sql.index(index, offsetBy: 2)
                        if blockDepth == 0 { output.append(" ") }
                        continue
                    }
                    if character == "/", next == "*" {
                        blockDepth += 1
                        index = sql.index(index, offsetBy: 2)
                        continue
                    }
                    index = sql.index(after: index)
                    continue
                }
                if let activeQuote = quote {
                    if character == activeQuote { quote = nil }
                    output.append(character)
                    index = sql.index(after: index)
                    continue
                }
                if character == "'" || character == "\"" {
                    quote = character
                    output.append(character)
                    index = sql.index(after: index)
                    continue
                }
                if character == "-", next == "-" {
                    while index < sql.endIndex, sql[index] != "\n" {
                        index = sql.index(after: index)
                    }
                    output.append(" ")
                    continue
                }
                if character == "/", next == "*" {
                    blockDepth = 1
                    index = sql.index(index, offsetBy: 2)
                    continue
                }
                output.append(character)
                index = sql.index(after: index)
            }
            return output
        }

        /// Names defined by `WITH name [ (cols) ] AS (` — exempt from the
        /// schema-evidence binding rule because they are query-local, not
        /// base tables.
        static func commonTableExpressionNames(in sql: String) -> Set<String> {
            var names = Set<String>()
            var searchStart = sql.startIndex
            while searchStart < sql.endIndex,
                let match = sql.range(
                    of: #"(?i)(?<![a-z0-9_])([a-z_][a-z0-9_]*)\s*(?:\([^()]*\))?\s+as\s*\("#,
                    options: .regularExpression,
                    range: searchStart..<sql.endIndex
                )
            {
                let matched = String(sql[match])
                if let nameMatch = matched.range(
                    of: #"^[a-zA-Z_][a-zA-Z0-9_]*"#,
                    options: .regularExpression
                ) {
                    names.insert(normalizedIdentifier(String(matched[nameMatch])))
                }
                searchStart = match.upperBound
            }
            return names
        }

        static func leadingQualifiedIdentifier(in value: String) -> String? {
            guard
                let match = value.range(
                    of: #"^[a-z_][a-z0-9_]*(\.[a-z_][a-z0-9_]*){0,2}"#,
                    options: .regularExpression
                )
            else { return nil }
            return String(value[match])
        }

        static func leadingIdentifierToken(in value: String) -> String? {
            guard
                let match = value.range(
                    of: #"^[a-z_][a-z0-9_]*"#,
                    options: .regularExpression
                )
            else { return nil }
            return String(value[match])
        }

        static func containsFunctionCall(named function: String, in sql: String) -> Bool {
            let pattern = #"(?i)(?<![a-z0-9_])"# + NSRegularExpression.escapedPattern(for: function)
                + #"\s*\("#
            return sql.range(of: pattern, options: .regularExpression) != nil
        }

        static func referencesIdentifier(_ identifier: String, in sql: String) -> Bool {
            let unqualified = identifier.split(separator: ".").last.map(String.init) ?? identifier
            guard !unqualified.isEmpty else { return false }
            let pattern = #"(?i)(?<![a-z0-9_])"#
                + NSRegularExpression.escapedPattern(for: unqualified)
                + #"(?![a-z0-9_])"#
            return sql.replacingOccurrences(of: "\"", with: "")
                .range(of: pattern, options: .regularExpression) != nil
        }

        static func containsTopLevelKeyword(_ keyword: String, in sql: String) -> Bool {
            topLevelKeywordIndex(keyword, in: sql) != nil
        }

        static func topLevelLimitValue(in sql: String) -> Int? {
            guard let index = topLevelKeywordIndex("limit", in: sql) else { return nil }
            let tail = sql[index...].dropFirst("limit".count)
            guard
                let match = tail.range(
                    of: #"^\s+(\d{1,9})"#,
                    options: .regularExpression
                )
            else { return nil }
            let digits = tail[match].trimmingCharacters(in: .whitespaces)
            return Int(digits)
        }

        private static func topLevelKeywordIndex(
            _ keyword: String, in sql: String
        ) -> String.Index? {
            var depth = 0
            var quote: Character?
            var index = sql.startIndex
            let pattern = #"^"#
                + keyword.split(separator: " ")
                    .map { NSRegularExpression.escapedPattern(for: String($0)) }
                    .joined(separator: #"\s+"#)
                + #"(?![a-z0-9_])"#
            while index < sql.endIndex {
                let character = sql[index]
                if let activeQuote = quote {
                    if character == activeQuote { quote = nil }
                    index = sql.index(after: index)
                    continue
                }
                switch character {
                case "'", "\"":
                    quote = character
                case "(":
                    depth += 1
                case ")":
                    depth = max(0, depth - 1)
                default:
                    if depth == 0, character.lowercased() == String(keyword.first ?? " ") {
                        let previousIsWordCharacter = index > sql.startIndex && {
                            let previous = sql[sql.index(before: index)]
                            return previous.isLetter || previous.isNumber || previous == "_"
                        }()
                        if !previousIsWordCharacter,
                            sql[index...].lowercased().range(
                                of: pattern, options: .regularExpression
                            ) != nil
                        {
                            return index
                        }
                    }
                }
                index = sql.index(after: index)
            }
            return nil
        }

        private static func lastTopLevelAliasRange(in expression: String) -> Range<String.Index>? {
            var depth = 0
            var quote: Character?
            var index = expression.startIndex
            var aliasRange: Range<String.Index>?
            while index < expression.endIndex {
                let character = expression[index]
                if let activeQuote = quote {
                    if character == activeQuote { quote = nil }
                    index = expression.index(after: index)
                    continue
                }
                switch character {
                case "'", "\"":
                    quote = character
                case "(":
                    depth += 1
                case ")":
                    depth = max(0, depth - 1)
                default:
                    if depth == 0, character == " " || character == "\n" || character == "\t",
                        let match = expression[index...].range(
                            of: #"^\s+as\s+("[^"]+"|[a-zA-Z_][a-zA-Z0-9_]*)\s*$"#,
                            options: [.regularExpression, .caseInsensitive]
                        )
                    {
                        let matched = expression[match]
                        if let aliasStart = matched.range(
                            of: #"("[^"]+"|[a-zA-Z_][a-zA-Z0-9_]*)\s*$"#,
                            options: .regularExpression
                        ) {
                            aliasRange = aliasStart
                        }
                    }
                }
                index = expression.index(after: index)
            }
            return aliasRange
        }

        private static func leadingFunctionName(in expression: String) -> String? {
            guard
                let match = expression.range(
                    of: #"^([a-z_][a-z0-9_]*)\s*\("#,
                    options: .regularExpression
                )
            else { return nil }
            let name = expression[match].dropLast().trimmingCharacters(
                in: CharacterSet(charactersIn: " (\t\n")
            )
            return name.isEmpty ? nil : name
        }

        private static func isPlainColumnPath(_ expression: String) -> Bool {
            expression.range(
                of: #"^[a-z_][a-z0-9_]*(\.[a-z_][a-z0-9_]*){0,2}$"#,
                options: .regularExpression
            ) != nil
        }

        private static func topLevelSelectExpressions(in sql: String) -> [String] {
            var searchStart = sql.startIndex
            var topLevelSelect: Range<String.Index>?
            while searchStart < sql.endIndex,
                let candidate = sql.range(
                    of: #"(?i)(?<![a-z0-9_])select\b"#,
                    options: .regularExpression,
                    range: searchStart..<sql.endIndex
                )
            {
                if isTopLevel(candidate.lowerBound, in: sql) {
                    topLevelSelect = candidate
                    break
                }
                searchStart = candidate.upperBound
            }
            guard let selectRange = topLevelSelect else { return [] }
            var index = selectRange.upperBound
            var depth = 0
            var quote: Character?
            var fromStart: String.Index?
            while index < sql.endIndex {
                let character = sql[index]
                if let activeQuote = quote {
                    if character == activeQuote { quote = nil }
                    index = sql.index(after: index)
                    continue
                }
                if character == "'" || character == "\"" {
                    quote = character
                    index = sql.index(after: index)
                    continue
                }
                if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth = max(0, depth - 1)
                } else if depth == 0,
                    sql[index...].range(
                        of: #"^\s+from(?![a-z0-9_])"#,
                        options: [.regularExpression, .caseInsensitive]
                    ) != nil
                {
                    fromStart = index
                    break
                }
                index = sql.index(after: index)
            }
            guard let fromStart else { return [] }
            return splitTopLevelCommaList(String(sql[selectRange.upperBound..<fromStart]))
        }

        private static func isTopLevel(_ position: String.Index, in sql: String) -> Bool {
            var depth = 0
            var quote: Character?
            var index = sql.startIndex
            while index < position {
                let character = sql[index]
                if let activeQuote = quote {
                    if character == activeQuote { quote = nil }
                } else {
                    switch character {
                    case "'", "\"": quote = character
                    case "(": depth += 1
                    case ")": depth = max(0, depth - 1)
                    default: break
                    }
                }
                index = sql.index(after: index)
            }
            return depth == 0 && quote == nil
        }

        private static func splitTopLevelCommaList(_ value: String) -> [String] {
            var expressions: [String] = []
            var start = value.startIndex
            var index = value.startIndex
            var depth = 0
            var quote: Character?
            while index < value.endIndex {
                let character = value[index]
                if let activeQuote = quote {
                    if character == activeQuote { quote = nil }
                    index = value.index(after: index)
                    continue
                }
                switch character {
                case "'", "\"":
                    quote = character
                case "(":
                    depth += 1
                case ")":
                    depth = max(0, depth - 1)
                case ",":
                    if depth == 0 {
                        expressions.append(String(value[start..<index]))
                        start = value.index(after: index)
                    }
                default:
                    break
                }
                index = value.index(after: index)
            }
            expressions.append(String(value[start...]))
            return expressions
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }
}
