import Foundation

/// Date groups are a projection: they never change message order or row identity.
enum ConversationTimePolicy {
    static func separators(
        for items: [ConversationTimelineItem],
        messages: [RichMessage],
        calendar: Calendar = .current
    ) -> [String: Date] {
        var datesBySequence: [Int: Date] = [:]
        for message in messages {
            if let date = date(for: message.timestamp) { datesBySequence[message.seq] = date }
        }
        var result: [String: Date] = [:]
        var lastDisplayedDate: Date?
        for item in items {
            let current: Date?
            switch item {
            case .message(let message):
                current = date(for: message.timestamp)
            case .toolGroup(_, let sequences, _):
                current = sequences.first.flatMap { datesBySequence[$0] }
            }
            guard let current else { continue }
            let startsGroup = lastDisplayedDate.map {
                !calendar.isDate(current, inSameDayAs: $0)
                    || current.timeIntervalSince($0) >= 5 * 60
            } ?? true
            if startsGroup {
                result[item.id] = current
                lastDisplayedDate = current
            }
        }
        return result
    }

    static func date(for timestamp: Double?) -> Date? {
        // Only dates representable within the supported civil calendar range.
        guard let timestamp, timestamp.isFinite, timestamp > 0,
              timestamp < 253_402_300_800 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    static func label(
        for date: Date,
        now: Date,
        locale: Locale = .current,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> String {
        var calendar = calendar
        calendar.timeZone = timeZone
        let time = Date.FormatStyle(date: .omitted, time: .shortened,
                                   locale: locale, calendar: calendar, timeZone: timeZone)
        let clock = date.formatted(time)
        if calendar.isDate(date, inSameDayAs: now) { return clock }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            // Foundation supplies the localized relative day name.
            let day = DateFormatter()
            day.locale = locale
            day.calendar = calendar
            day.timeZone = timeZone
            day.dateStyle = .medium
            day.doesRelativeDateFormatting = true
            // Relative date formatting is tied to the real current date. The
            // explicit comparison above determines the intended day group.
            if calendar.isDate(now, inSameDayAs: Date()) {
                return "\(day.string(from: date)) \(clock)"
            }
        }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
            .month(.abbreviated).day()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            style = style.year()
        }
        return "\(date.formatted(style)) \(clock)"
    }
}
