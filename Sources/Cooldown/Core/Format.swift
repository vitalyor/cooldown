import Foundation

// l10n:file-skip — texts here are already wrapped in L().
enum Format {
    private static let hourMinute: DateFormatter = make("HHmm")
    private static let weekdayTime: DateFormatter = make("EEEHHmm")
    private static let dayMonth: DateFormatter = make("dMMMM")

    /// Formatters from templates, so each language gets its own order and words.
    private static func make(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// "11:15", "tomorrow at 09:40" or "Fri 10:56".
    static func time(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return hourMinute.string(from: date) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return L("завтра в %@", hourMinute.string(from: date))
        }
        return weekdayTime.string(from: date)
    }

    static func clock(_ date: Date) -> String { hourMinute.string(from: date) }

    /// "18 October".
    static func day(_ date: Date) -> String { dayMonth.string(from: date) }

    /// A word that agrees with the number: `forms` is "one|few|many" in the person's language
    /// (as many forms as it has).
    static func word(_ n: Int, _ forms: String) -> String {
        let parts = forms.components(separatedBy: "|")
        return parts[min(parts.count - 1, AppLanguage.pluralIndex(n, forms: parts.count))]
    }

    /// The number and its word: "3 задачи", "3 tasks".
    static func count(_ n: Int, _ forms: String) -> String { L("%@ %@", "\(n)", word(n, forms)) }

    static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return hours > 0 ? L("%@ д %@ ч", "\(days)", "\(hours)") : L("%@ д", "\(days)") }
        if hours > 0 { return minutes > 0 ? L("%@ ч %@ мин", "\(hours)", "\(minutes)") : L("%@ ч", "\(hours)") }
        if minutes > 0 { return L("%@ мин", "\(minutes)") }
        return L("меньше минуты")
    }

    static func tokens(_ count: Int) -> String {
        let value = Double(count)
        if value >= 1e9 { return L("%@ млрд", decimal(value / 1e9)) }
        if value >= 1e6 { return L("%@ млн", decimal(value / 1e6)) }
        if value >= 1e4 { return L("%@ тыс.", "\(Int((value / 1e3).rounded()))") }
        if value >= 1e3 { return L("%@ тыс.", decimal(value / 1e3)) }
        return "\(count)"
    }

    static func tokensAxis(_ count: Int) -> String {
        let value = Double(count)
        if value >= 1e9 { return decimal(value / 1e9) + "B" }
        if value >= 1e6 { return decimal(value / 1e6) + "M" }
        if value >= 1e3 { return "\(Int((value / 1e3).rounded()))K" }
        return "\(count)"
    }

    private static func decimal(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return "\(Int(rounded))" }
        return rounded.formatted(.number.precision(.fractionLength(1)).locale(AppLanguage.locale))
    }

    static func updated(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return L("обновлено только что") }
        return L("обновлено %@ назад", duration(seconds))
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return L("только что") }
        if seconds < 3600 { return L("%@ мин назад", "\(Int(seconds / 60))") }
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return L("сегодня в %@", hourMinute.string(from: date)) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return L("вчера в %@", hourMinute.string(from: date))
        }
        return dayMonth.string(from: date)
    }

}
