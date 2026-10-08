import Foundation

/// A five-field cron expression: minute, hour, day of month, month, day of week.
///
/// Supports `*`, lists, ranges, and steps. Day of week runs 0 to 6 from Sunday,
/// with 7 accepted as Sunday. As in cron, when both day fields are restricted a
/// date matches if either does.
public struct CronExpression: Sendable, Equatable, Codable {
    public let expression: String
    let minutes: Set<Int>
    let hours: Set<Int>
    let daysOfMonth: Set<Int>
    let months: Set<Int>
    let daysOfWeek: Set<Int>
    let restrictsDayOfMonth: Bool
    let restrictsDayOfWeek: Bool

    public struct ParseError: Error, Sendable, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public init(_ expression: String) throws {
        let fields = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5 else { throw ParseError(message: "cron needs five fields, got \(fields.count): \(expression)") }
        self.expression = fields.joined(separator: " ")
        minutes = try Self.parse(fields[0], range: 0...59)
        hours = try Self.parse(fields[1], range: 0...23)
        daysOfMonth = try Self.parse(fields[2], range: 1...31)
        months = try Self.parse(fields[3], range: 1...12)
        daysOfWeek = Set(try Self.parse(fields[4], range: 0...7).map { $0 == 7 ? 0 : $0 })
        restrictsDayOfMonth = fields[2] != "*"
        restrictsDayOfWeek = fields[4] != "*"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(expression)
    }

    static func parse(_ field: String, range: ClosedRange<Int>) throws -> Set<Int> {
        var values = Set<Int>()
        for part in field.split(separator: ",") {
            let (base, step) = part.split(separator: "/", maxSplits: 1).count == 2
                ? (String(part.split(separator: "/")[0]), Int(part.split(separator: "/")[1]))
                : (String(part), nil)
            if part.contains("/"), step == nil || step! <= 0 { throw ParseError(message: "bad step in \(part)") }
            var low: Int
            var high: Int
            if base == "*" {
                low = range.lowerBound
                high = range.upperBound
            } else if base.contains("-") {
                let bounds = base.split(separator: "-").compactMap { Int($0) }
                guard bounds.count == 2 else { throw ParseError(message: "bad range \(base)") }
                low = bounds[0]
                high = bounds[1]
            } else if let value = Int(base) {
                low = value
                high = step == nil ? value : range.upperBound
            } else {
                throw ParseError(message: "bad field \(base)")
            }
            guard range.contains(low), range.contains(high), low <= high else { throw ParseError(message: "\(base) is outside \(range)") }
            values.formUnion(stride(from: low, through: high, by: step ?? 1))
        }
        return values
    }

    func matchesDay(_ components: DateComponents) -> Bool {
        guard let month = components.month, months.contains(month) else { return false }
        let dom = daysOfMonth.contains(components.day ?? 0)
        let dow = daysOfWeek.contains((components.weekday ?? 1) - 1)
        switch (restrictsDayOfMonth, restrictsDayOfWeek) {
        case (true, true): return dom || dow
        case (true, false): return dom
        case (false, true): return dow
        case (false, false): return true
        }
    }

    /// The first matching minute strictly after `date`, or nil within four years.
    public func nextDate(after date: Date, timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Start at the next whole minute.
        var candidate = calendar.date(bySetting: .second, value: 0, of: date).map { $0 <= date ? $0.addingTimeInterval(60) : $0 } ?? date
        candidate = calendar.date(bySetting: .nanosecond, value: 0, of: candidate) ?? candidate
        let limit = calendar.date(byAdding: .year, value: 4, to: date) ?? date
        while candidate < limit {
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: candidate)
            if !matchesDay(components) {
                guard let start = calendar.date(from: DateComponents(year: components.year, month: components.month, day: components.day)),
                    let next = calendar.date(byAdding: .day, value: 1, to: start)
                else { return nil }
                candidate = next
                continue
            }
            if !hours.contains(components.hour ?? -1) {
                guard let start = calendar.date(from: DateComponents(year: components.year, month: components.month, day: components.day, hour: components.hour)),
                    let next = calendar.date(byAdding: .hour, value: 1, to: start)
                else { return nil }
                candidate = next
                continue
            }
            if minutes.contains(components.minute ?? -1) {
                return candidate
            }
            candidate = candidate.addingTimeInterval(60)
        }
        return nil
    }
}
