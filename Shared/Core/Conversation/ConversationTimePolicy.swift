import Foundation
import Observation
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Shared calendar-day clock for relative time separators (`Today` / `Yesterday`),
/// waking only on midnight and significant clock/timezone changes rather than
/// spinning a 60s timer per row.
@MainActor
@Observable
final class CalendarDayClock {
    static let shared = CalendarDayClock()

    private(set) var today: Date
    @ObservationIgnored private var activeDayStart: Date
    @ObservationIgnored private var activeCalendar: Calendar
    @ObservationIgnored private var midnightTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        let now = Date()
        let calendar = Calendar.current
        self.today = now
        self.activeCalendar = calendar
        self.activeDayStart = calendar.startOfDay(for: now)
        installObservers()
        scheduleMidnightRefresh()
    }

    private func installObservers() {
        var names: [Notification.Name] = [
            .NSCalendarDayChanged,
            .NSSystemTimeZoneDidChange,
            .NSSystemClockDidChange,
        ]
        #if os(macOS)
        names.append(NSApplication.didBecomeActiveNotification)
        #elseif canImport(UIKit)
        names.append(UIApplication.significantTimeChangeNotification)
        names.append(UIApplication.didBecomeActiveNotification)
        #endif
        for name in names {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                    self?.scheduleMidnightRefresh()
                }
            }
            observers.append(token)
        }
    }

    func refresh() {
        let now = Date()
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        guard dayStart != activeDayStart || calendar != activeCalendar else { return }
        activeDayStart = dayStart
        activeCalendar = calendar
        today = now
    }

    private func scheduleMidnightRefresh() {
        midnightTask?.cancel()
        midnightTask = Task { [weak self] in
            while !Task.isCancelled {
                let now = Date()
                guard let end = Calendar.current.dateInterval(of: .day, for: now)?.end else { return }
                do {
                    try await Task.sleep(for: .seconds(max(0.5, end.timeIntervalSince(now))))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }
}

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
            // Relative date formatting is tied to the real current date. The
            // explicit comparison above determines the intended day group.
            if calendar.isDate(now, inSameDayAs: Date()) {
                let relative = RelativeDayCache.shared.dayString(
                    for: date, locale: locale, calendar: calendar, timeZone: timeZone
                )
                return "\(relative) \(clock)"
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

private final class RelativeDayCache: @unchecked Sendable {
    static let shared = RelativeDayCache()

    private struct Key: Hashable {
        let locale: String
        let calendar: Calendar.Identifier
        let timeZone: String
    }

    private let lock = NSLock()
    private var formatters: [Key: DateFormatter] = [:]

    func dayString(for date: Date, locale: Locale, calendar: Calendar, timeZone: TimeZone) -> String {
        let key = Key(
            locale: locale.identifier,
            calendar: calendar.identifier,
            timeZone: timeZone.identifier
        )
        lock.lock()
        defer { lock.unlock() }
        let formatter: DateFormatter
        if let cached = formatters[key] {
            formatter = cached
        } else {
            let built = DateFormatter()
            built.locale = locale
            built.calendar = calendar
            built.timeZone = timeZone
            built.dateStyle = .medium
            built.doesRelativeDateFormatting = true
            if formatters.count >= 8 { formatters.removeAll(keepingCapacity: true) }
            formatters[key] = built
            formatter = built
        }
        return formatter.string(from: date)
    }
}
