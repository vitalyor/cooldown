import ApplicationServices
import AppKit
import Combine
import SwiftUI
import UserNotifications

/// The guided setup: each agent's state with the one thing to do next, and written steps for
/// when that one thing doesn't work.
@MainActor
final class SetupWindow: NSObject, NSWindowDelegate {
    static let shared = SetupWindow()
    private var window: NSWindow?

    func show() {
        if window == nil { window = make() }
        StatusController.shared?.close()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Once, on the first start, if something needs doing.
    func showOnFirstRun() {
        Task {
            await AgentSetup.shared.refresh()
            guard !UserDefaults.standard.bool(forKey: "setupShown"), !DemoController.shared.active else { return }
            UserDefaults.standard.set(true, forKey: "setupShown")
            if ProviderID.agents.contains(where: AgentSetup.shared.needsHelp) { show() }
        }
    }

    func make(onScreen: Bool = true) -> NSWindow {
        let controller = NSHostingController(rootView: SetupView())
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.title = L("Настройка Cooldown")
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 620, height: 720))
        window.isReleasedWhenClosed = false
        if onScreen { window.center() }
        window.delegate = self
        return window
    }

    func windowDidBecomeKey(_ notification: Notification) { Task { await AgentSetup.shared.refresh() } }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}

struct SetupView: View {
    @ObservedObject private var setup = AgentSetup.shared
    @State private var copied = false
    @State private var checking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Настройка Cooldown")).font(.system(size: 26, weight: .bold, design: .rounded))
                    Text(L("Чтобы показывать лимиты, Cooldown нужны Claude Code и Codex на этом Mac. Пройдите шаги ниже: всё делается здесь, кроме входа в браузере."))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                AgentCard(provider: .claude)
                AgentCard(provider: .codex)
                PermissionsCard()
                Well {
                    Label(L("Попросить нейросеть"), systemImage: "sparkles").font(.system(size: 14, weight: .semibold))
                    Footnote(text: L("Если вы пользуетесь Claude Code, Codex или другим помощником, который умеет выполнять команды, скопируйте текст и вставьте ему. Он сделает всё сам и объяснит каждый шаг."))
                    Button {
                        copy(SetupGuide.assistantPrompt())
                        copied = true
                    } label: {
                        Label(copied ? L("Скопировано") : L("Скопировать текст для нейросети"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
                HStack {
                    Button {
                        checking = true
                        Task { await setup.refresh(); checking = false }
                    } label: {
                        HStack(spacing: 6) {
                            if checking { ProgressView().controlSize(.small) }
                            Text(L("Проверить снова"))
                        }
                    }
                    .disabled(checking)
                    Spacer()
                    Button(L("Готово")) { NSApp.keyWindow?.close() }.buttonStyle(.glassProminent)
                }
            }
            .padding(24)
            .padding(.top, 12)
        }
        .frame(width: 620, height: 720)
        .task { await setup.refresh() }
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private struct AgentCard: View {
    let provider: ProviderID
    @ObservedObject private var setup = AgentSetup.shared
    @State private var showSteps = false
    @State private var code = ""

    private var agent: AgentSetup.Agent { setup.agent(provider) }
    private var isSkipped: Bool { setup.skipped.contains(provider) }

    var body: some View {
        Well {
            HStack(spacing: 10) {
                Circle().fill(Theme.tint(for: provider)).frame(width: 10, height: 10)
                Text(provider.toolName).font(.system(size: 16, weight: .semibold))
                Spacer()
                status
            }
            if isSkipped {
                Footnote(text: L("Вы отметили, что не пользуетесь %@: его вкладка и линия в строке меню скрыты.", provider.toolName))
                Button(L("Всё же настроить")) { setup.setSkipped(provider, false) }
            } else {
                action
                if let problem = agent.problem {
                    Note(symbol: "exclamationmark.triangle.fill", text: problem, color: Theme.amber)
                }
                if agent.stage != .ready && agent.stage != .checking {
                    DisclosureGroup(L("Не получается? Подробная инструкция"), isExpanded: $showSteps) { steps.padding(.top, 8) }
                    Button(L("Я не пользуюсь %@", provider.toolName)) { setup.setSkipped(provider, true) }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: agent.problem) { _, problem in if problem != nil { showSteps = true } }
    }

    @ViewBuilder private var status: some View {
        switch agent.stage {
        case .ready: Label(L("Готово"), systemImage: "checkmark.circle.fill").foregroundStyle(Theme.mint).font(.callout)
        case .checking: ProgressView().controlSize(.small)
        case .missing: Text(L("Не установлен")).foregroundStyle(.secondary).font(.callout)
        case .installing: Text(L("Устанавливается")).foregroundStyle(.secondary).font(.callout)
        case .signedOut: Text(L("Нужен вход")).foregroundStyle(Theme.amber).font(.callout)
        case .signingIn: Text(L("Вход")).foregroundStyle(.secondary).font(.callout)
        }
    }

    @ViewBuilder private var action: some View {
        switch agent.stage {
        case .missing:
            Footnote(text: provider == .claude
                     ? L("Cooldown скачает официальную программу Anthropic в вашу домашнюю папку. Пароль не понадобится. Нужен платный тариф Claude: в бесплатный Claude Code не входит.")
                     : L("Cooldown скачает официальную программу OpenAI в вашу домашнюю папку. Пароль не понадобится."))
            Button(L("Установить %@", provider.toolName)) { setup.install(provider) }.buttonStyle(.glassProminent).tint(Theme.tint(for: provider))
        case .installing:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("Скачиваю и устанавливаю, это займёт пару минут…")).foregroundStyle(.secondary) }
        case .signedOut:
            Footnote(text: L("Осталось войти в аккаунт. Откроется браузер: подтвердите вход и вернитесь сюда, остальное Cooldown сделает сам. Пароль Cooldown не видит."))
            Button(L("Войти в %@", provider.toolName)) { setup.signIn(provider) }.buttonStyle(.glassProminent).tint(Theme.tint(for: provider))
        case .signingIn:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("Жду подтверждения в браузере…")).foregroundStyle(.secondary) }
            if let url = agent.loginURL {
                Link(L("Браузер не открылся? Открыть страницу входа"), destination: url).font(.callout)
            }
            if agent.asksForCode {
                Footnote(text: L("Если браузер показал код, вставьте его сюда:"))
                HStack {
                    TextField(L("Код из браузера"), text: $code).textFieldStyle(.roundedBorder)
                    Button(L("Отправить")) { setup.sendCode(code, to: provider); code = "" }.disabled(code.isEmpty)
                }
            }
            Button(L("Отмена")) { setup.cancelSignIn(provider) }
        case .ready:
            Footnote(text: L("Подключено. Лимиты появятся в Cooldown автоматически."))
        case .checking:
            EmptyView()
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(L("Сделать всё в Терминале")) { setup.openInTerminal(provider) }
            step(1, L("Откройте Терминал: нажмите ⌘ и Пробел, введите «Терминал» и нажмите Return."))
            step(2, L("Вставьте команду и нажмите Return. Она скачает официальную программу, пароль не нужен."), command: SetupGuide.install(provider))
            step(3, L("Если загрузка не удалась, включите VPN и повторите. Либо установите через Homebrew, если он у вас есть:"), command: SetupGuide.homebrew(provider))
            step(4, L("Войдите в аккаунт. Откроется браузер, подтвердите вход:"), command: SetupGuide.signIn(provider))
            step(5, L("Проверьте, что вход выполнен:"), command: SetupGuide.check(provider))
            step(6, L("Вернитесь сюда и нажмите «Проверить снова»."))
        }
        .font(.callout)
    }

    private func step(_ number: Int, _ text: String, command: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)").font(.caption.weight(.bold)).frame(width: 22, height: 22).background(Circle().fill(Color.primary.opacity(0.1)))
            VStack(alignment: .leading, spacing: 6) {
                Text(text).fixedSize(horizontal: false, vertical: true)
                if let command { CommandRow(command: command) }
            }
        }
    }
}

private struct CommandRow: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Button { copy(command); copied = true } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                .buttonStyle(.plain).help(L("Скопировать"))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
    }
}

/// The two things only macOS can grant: where to click, and whether it is done yet.
private struct PermissionsCard: View {
    @State private var accessibility = ClaudeSender.hasPermission
    @State private var notifications: Bool?
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Well {
            Text(L("Разрешения macOS")).font(.system(size: 16, weight: .semibold))
            Footnote(text: L("Их может выдать только сам человек, поэтому Cooldown откроет нужный раздел настроек."))
            row(L("Универсальный доступ"), ok: accessibility,
                detail: L("Нужен, чтобы видеть ответы Claude Desktop и продолжать чаты. В открывшемся окне включите переключатель рядом с Cooldown.")) {
                ClaudeSender.requestPermission()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            row(L("Уведомления"), ok: notifications ?? true,
                detail: L("Нужны, чтобы сообщать о лимитах, пока вы не смотрите на экран. Найдите Cooldown в списке и разрешите уведомления.")) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
            }
        }
        .task { await update() }
        .onReceive(timer) { _ in Task { await update() } }
    }

    private func update() async {
        accessibility = ClaudeSender.hasPermission
        guard Bundle.main.bundleIdentifier != nil else { return }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notifications = status == .authorized || status == .provisional
    }

    private func row(_ title: String, ok: Bool, detail: String, open: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !ok { Footnote(text: detail) }
            }
            Spacer()
            if ok {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.mint).accessibilityLabel(L("Готово"))
            } else {
                Button(L("Открыть настройки"), action: open)
            }
        }
    }
}

/// On the limits tab, in place of an error, when an agent still needs setting up.
struct SetupPrompt: View {
    let provider: ProviderID
    @ObservedObject private var setup = AgentSetup.shared

    var body: some View {
        Well {
            Label(setup.agent(provider).stage == .missing ? L("%@ не установлен", provider.toolName) : L("Войдите в %@", provider.toolName),
                  systemImage: "wand.and.stars").font(.system(size: 14, weight: .semibold))
            Footnote(text: L("Без этого Cooldown не может показать лимиты. Настройка займёт пару минут."))
            Button(L("Настроить")) { SetupWindow.shared.show() }.buttonStyle(.glassProminent).tint(Theme.tint(for: provider))
        }
    }
}
