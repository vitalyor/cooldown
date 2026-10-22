import Foundation

/// Things worth saying that come from the numbers rather than from one event: the 5-hour limit
/// running out sooner than its reset while an agent works, one project eating the week, and a
/// short look back at the week. Each is said once (per window, per project, per week).
@MainActor
enum Insights {
    private static var said: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "insightsSaid") ?? []) }
        set { UserDefaults.standard.set(Array(newValue.suffix(200)), forKey: "insightsSaid") }
    }

    private static func once(_ key: String) -> Bool {
        var keys = said
        guard !keys.contains(key) else { return false }
        keys.insert(key)
        said = keys
        return true
    }

    // MARK: Pace

    /// Called after fresh limits: while an agent of this provider works and its current pace
    /// empties the 5-hour window before the reset, say when (once per window).
    static func checkPace(_ store: ProviderStore) {
        guard Settings.notifyPace, !AppModel.shared.demoActive, !AgentActivity.shared.working(store.id).isEmpty,
              let window = store.snapshot?.session, !window.isExpired(at: Date()) else { return }
        let now = Date()
        let forecast = Forecaster.make(window: window, samples: store.samples, now: now)
        guard case .runsOut(let at) = forecast.outcome else { return }
        let ahead = at.timeIntervalSince(now)
        // Worth a word only when it is near enough to plan around and not already a done deal.
        guard ahead > 5 * 60, ahead < 75 * 60, window.resetsAt.timeIntervalSince(at) > 10 * 60 else { return }
        guard once("pace-\(store.id.rawValue)-\(Int(window.resetsAt.timeIntervalSince1970))") else { return }
        let name = store.id.displayName
        Notifier.shared.post(id: "pace-\(store.id.rawValue)-\(Int(now.timeIntervalSince1970))",
                             title: L("%@: лимит кончится около %@", "\(name)", "\(Format.clock(at))"),
                             body: L("При таком темпе 5 часов закончатся раньше сброса в %@.", "\(Format.clock(window.resetsAt))"),
                             toast: ToastContent(key: "pace-\(store.id.rawValue)", kind: .attention, provider: store.id,
                                                 title: L("%@: лимит кончится около %@", "\(name)", "\(Format.clock(at))"),
                                                 body: L("При таком темпе 5 часов закончатся раньше сброса в %@. Сейчас осталось %@.", "\(Format.clock(window.resetsAt))", "\(Format.percent(window.remainingPercent))"),
                                                 actions: store.id == .codex ? [.openSchedule, .openPanel] : [.openPanel], life: .auto(14)))
    }

    // MARK: Projects

    /// One project taking a large part of this week's limit (estimated from its share of tokens).
    static func checkProjects(_ store: ProviderStore) {
        // Only Codex: all of its work is in its session files. Claude's limit is spent mostly in
        // Claude Desktop chats, which leave no token counts on disk, so a Claude Code folder's
        // share of tokens says nothing about its share of the Claude limit.
        guard store.id == .codex, Settings.notifyProjects, !AppModel.shared.demoActive, let week = store.snapshot?.weekly,
              !week.isExpired(at: Date()), week.usedPercent >= 25 else { return }
        let inWindow = store.buckets.filter { $0.key.hour >= week.start && !$0.key.project.hasPrefix(Settings.appSupport.path) }
        let total = inWindow.reduce(0) { $0 + $1.counts.total }
        guard total > 0 else { return }
        var perProject: [String: Int] = [:]
        for bucket in inWindow { perProject[bucket.key.project, default: 0] += bucket.counts.total }
        for (project, tokens) in perProject {
            let share = Double(tokens) / Double(total)
            let ofLimit = share * week.usedPercent
            guard share >= 0.4, ofLimit >= 20 else { continue }
            let name = Stats.projectName(project)
            guard once("project-\(store.id.rawValue)-\(Int(week.resetsAt.timeIntervalSince1970))-\(project)") else { continue }
            Notifier.shared.post(id: "project-\(store.id.rawValue)-\(name)-\(Int(Date().timeIntervalSince1970))",
                                 title: L("«%@» — около %@ недели %@", "\(name)", "\(Format.percent(ofLimit))", "\(store.id.displayName)"),
                                 body: L("На этот проект ушло %@ работы %@ с начала недели.", "\(Format.percent(share * 100))", "\(store.id.displayName)"),
                                 toast: ToastContent(key: "project-\(name)", kind: .info, provider: store.id,
                                                     title: L("«%@»: около %@ недельного лимита", "\(name)", "\(Format.percent(ofLimit))"),
                                                     body: L("На этот проект ушло %@ работы %@ с начала недели. Всего неделя израсходована на %@.", "\(Format.percent(share * 100))", "\(store.id.displayName)", "\(Format.percent(week.usedPercent))"),
                                                     actions: [.openPanel], life: .auto(12)))
        }
    }

    // MARK: The day

    /// In the evening: if today took clearly more of the week than the week can afford per day.
    static func checkDay() {
        guard Settings.notifyPace, !AppModel.shared.demoActive, !QuietHours.active,
              Calendar.current.component(.hour, from: Date()) >= 20 else { return }
        let now = Date()
        for store in [AppModel.shared.codex, AppModel.shared.claude] {
            guard let week = store.snapshot?.weekly, !week.isExpired(at: now) else { continue }
            let today = DailyLog.shared.day(now)
            let spent = store.id == .codex ? today.codexWeek : today.claudeWeek
            // What a day could take at the start of today: what was left then, over the days left.
            let leftAtStart = week.remainingPercent + spent
            let days = max(1, (week.resetsAt.timeIntervalSince(Calendar.current.startOfDay(for: now)) / 86400).rounded(.up))
            let budget = leftAtStart / days
            guard spent >= 8, spent > budget * 1.3 else { continue }
            guard once("day-\(store.id.rawValue)-\(DailyLog.key(now))") else { continue }
            let name = store.id.displayName
            Notifier.shared.post(id: "day-\(store.id.rawValue)-\(DailyLog.key(now))",
                                 title: L("%@: сегодня ушло %@ недели", "\(name)", "\(Format.percent(spent))"),
                                 body: L("Чтобы хватило до сброса, в день можно около %@.", "\(Format.percent(budget))"),
                                 toast: ToastContent(key: "day-\(store.id.rawValue)", kind: .info, provider: store.id,
                                                     title: L("%@: сегодня ушло %@ недели", "\(name)", "\(Format.percent(spent))"),
                                                     body: L("Чтобы недельного лимита хватило до сброса %@, в день можно около %@. Завтра стоит полегче.", "\(Format.time(week.resetsAt))", "\(Format.percent(budget))"),
                                                     actions: [.openPanel], life: .auto(14)))
        }
    }

    // MARK: The week

    /// Sunday evening, when someone is at the Mac: what the week came to.
    static func checkWeek() {
        guard Settings.weeklySummary, !AppModel.shared.demoActive, !QuietHours.active,
              ToastController.shared.canShow, ToastController.idleSeconds < 120 else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        let now = Date()
        guard calendar.component(.weekday, from: now) == 1, calendar.component(.hour, from: now) >= 18 else { return }
        let week = calendar.component(.weekOfYear, from: now), year = calendar.component(.yearForWeekOfYear, from: now)
        guard once("week-\(year)-\(week)") else { return }

        let model = AppModel.shared
        let log = DailyLog.shared
        var codexTokens = 0, claudeTokens = 0, dollars = 0.0, done = 0
        for offset in 0..<7 {
            let day = log.day(calendar.date(byAdding: .day, value: -offset, to: now)!)
            codexTokens += day.codexTokens
            claudeTokens += day.claudeTokens
            dollars += day.codexDollars + day.claudeDollars
            done += day.codexDone + day.claudeDone
        }
        var parts: [String] = []
        if codexTokens > 0 { parts.append(L("Codex: %@ токенов", "\(Format.tokens(codexTokens))")) }
        if claudeTokens > 0 { parts.append("Claude Code: \(Format.tokens(claudeTokens))") }
        if dollars >= 1 { parts.append(L("по API это стоило бы ≈%@", "\(Pricing.format(dollars))")) }
        if done > 0 { parts.append(L("закончено задач: %@", "\(done)")) }
        let exhausted = Stats.exhaustedWindows(model.codex.samples, .week, now: now) + Stats.exhaustedWindows(model.claude.samples, .week, now: now)
        if exhausted > 0 { parts.append(L("в лимит упирались %@", "\(Format.count(exhausted, L("раз|раза|раз")))")) }
        let top = Stats.projects(model.codex.buckets + model.claude.buckets, .week, now: now).first
        if let top { parts.append(L("больше всего — «%@»", "\(top.name)")) }
        guard !parts.isEmpty else { return }
        // The week as a picture to keep or share.
        let report = WeeklyReport.render(now: now)
        ToastController.shared.show(ToastContent(key: "week", kind: .info, provider: nil, title: L("Итоги недели"),
                                                 body: parts.joined(separator: ", ") + ".",
                                                 actions: report.map { [.openFile($0), .openPanel] } ?? [.openPanel], life: .sticky))
    }
}
