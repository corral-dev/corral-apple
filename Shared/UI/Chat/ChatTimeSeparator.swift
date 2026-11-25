import SwiftUI

/// Quiet time metadata belongs to a timeline row, preserving its scroll anchor.
struct ChatTimeSeparator: View {
    let date: Date
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        Text(ConversationTimePolicy.label(
            for: date, now: CalendarDayClock.shared.today, locale: locale,
            calendar: calendar, timeZone: timeZone
        ))
        .interfaceFont(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .interfaceFrame(maxWidth: .infinity, alignment: .center)
        .interfacePadding(.vertical, Space.sm)
        .accessibilityLabel(Text(date, format: .dateTime.year().month().day().hour().minute()))
        .accessibilityIdentifier("chat.time-separator")
    }
}

