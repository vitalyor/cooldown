import Foundation

enum Format {
    private static let ru = Locale(identifier: "ru_RU")

    private static let hourMinute: DateFormatter = make("HH:mm")
    private static let weekdayTime: DateFormatter = make("EEEEEE, HH:mm")
    private static let dayMonth: DateFormatter = make("d MMMM")

    private static func make(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = ru
        formatter.dateFormat = format
        return formatter
    }

    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// "11:15", "завтра в 09:40" or "пт, 10:56".
    static func time(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return hourMinute.string(from: date) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "завтра в " + hourMinute.string(from: date)
        }
        return weekdayTime.string(from: date)
    }

    static func clock(_ date: Date) -> String { hourMinute.string(from: date) }

    /// "18 октября".
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM"
        return formatter.string(from: date)
    }

    static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return hours > 0 ? "\(days) д \(hours) ч" : "\(days) д" }
        if hours > 0 { return minutes > 0 ? "\(hours) ч \(minutes) мин" : "\(hours) ч" }
        if minutes > 0 { return "\(minutes) мин" }
        return "меньше минуты"
    }

    static func tokens(_ count: Int) -> String {
        let value = Double(count)
        if value >= 1e9 { return decimal(value / 1e9) + " млрд" }
        if value >= 1e6 { return decimal(value / 1e6) + " млн" }
        if value >= 1e4 { return "\(Int((value / 1e3).rounded())) тыс." }
        if value >= 1e3 { return decimal(value / 1e3) + " тыс." }
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
        return String(format: "%.1f", rounded).replacingOccurrences(of: ".", with: ",")
    }

    static func updated(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "обновлено только что" }
        return "обновлено \(duration(seconds)) назад"
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "только что" }
        if seconds < 3600 { return "\(Int(seconds / 60)) мин назад" }
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "сегодня в " + hourMinute.string(from: date) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "вчера в " + hourMinute.string(from: date)
        }
        return dayMonth.string(from: date)
    }

    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let n10 = n % 10
        let n100 = n % 100
        if n10 == 1 && n100 != 11 { return one }
        if (2...4).contains(n10) && !(12...14).contains(n100) { return few }
        return many
    }
}
