import SwiftUI
import UserNotifications

/// Settings › Notifications: iOS permission, the app-level switch, and for
/// every saved server this iPhone's preferences on that server — the same
/// preferences the codeg desktop shows per device (`list_push_devices` /
/// `update_push_device_prefs`) — plus "Send test push", and the server's
/// reminders of what still waits (`get_pending_reminder_settings` /
/// `update_pending_reminder_settings`).
struct NotificationsSettingsView: View {
    let store: ServerStore

    @State private var model = NotificationsSettingsModel()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openURL) private var openURL
    private var push: PushRegistration { PushRegistration.shared }

    var body: some View {
        ZStack {
            CodegBackground()
            ScrollView {
                VStack(spacing: 22) {
                    permissionSection
                    if push.enabled && push.isAllowed {
                        ForEach(model.entries) { entry in
                            serverSection(entry)
                        }
                    }
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollContentBackground(.hidden)
        }
        .screenTitle("Notifications", compact: horizontalSizeClass == .compact)
        .task {
            await push.refreshAuthorization()
            await model.load(servers: store.servers)
        }
        .onChange(of: push.registrationTick) { _, _ in
            Task { await model.load(servers: store.servers) }
        }
        .refreshable { await model.load(servers: store.servers) }
    }

    // MARK: - Permission

    private var permissionSection: some View {
        EditorSection(
            title: "This iPhone",
            footer: "Turn finished, needs you, critical and error alerts come from each codeg server you saved. Turning this off makes every server forget this iPhone, so critical alerts fall back to your chat channels."
        ) {
            settingRow("Push notifications", hint: permissionHint) {
                Toggle("", isOn: Binding(get: { push.enabled }, set: { push.enabled = $0 }))
                    .labelsHidden()
                    .tint(Theme.accent)
            }
            if push.enabled {
                rowDivider
                switch push.authorization {
                case .notDetermined:
                    actionRow("Allow notifications", systemImage: "bell.badge") {
                        Task {
                            if await push.requestAuthorizationIfNeeded() { await push.registerAll() }
                        }
                    }
                case .denied:
                    actionRow("Open iOS Settings", systemImage: "gearshape") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                    }
                default:
                    settingRow("Environment", hint: "Which APNs servers this build's token belongs to.") {
                        Text(verbatim: APNsEnvironment.current)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            if let error = push.lastError {
                rowDivider
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var permissionHint: LocalizedStringKey {
        guard push.enabled else { return "Off: no server sends alerts to this iPhone." }
        switch push.authorization {
        case .authorized, .provisional, .ephemeral:
            return push.deviceToken == nil ? "Allowed. Waiting for a device token from Apple…" : "Allowed."
        case .denied: return "Notifications are turned off for this app in iOS Settings."
        default: return "Not allowed yet."
        }
    }

    // MARK: - Per server

    @ViewBuilder
    private func serverSection(_ entry: NotificationsSettingsModel.Entry) -> some View {
        EditorSection(title: LocalizedStringKey(entry.profile.name),
                      footer: "“Only when away” means no codeg window on a desktop or in a browser is in use. Nothing is pushed about a session someone is looking at.") {
            switch entry.state {
            case .loading:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(.subheadline).foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                .padding(16)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: message)
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                    Text("This server may not support iPhone push yet (it needs codeg's push backend).")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                rowDivider
                actionRow("Try again", systemImage: "arrow.clockwise") {
                    Task { await model.reload(entry.id, servers: store.servers) }
                }
            case .notRegistered:
                settingRow("Not registered", hint: push.serverErrors[entry.id].map { LocalizedStringKey($0) }
                           ?? "This iPhone is not on this server's device list yet.") { EmptyView() }
                rowDivider
                actionRow("Register this iPhone", systemImage: "iphone.radiowaves.left.and.right") {
                    Task { await model.registerNow(entry.id, servers: store.servers) }
                }
            case .loaded:
                if let device = entry.device {
                    prefsRows(entry, device: device)
                }
            }
        }
    }

    @ViewBuilder
    private func prefsRows(_ entry: NotificationsSettingsModel.Entry, device: PushDeviceView) -> some View {
        settingRow("Turn finished", hint: "An agent finished responding.") {
            deliveryMenu(device.prefs.turnFinished) { value in
                var prefs = device.prefs
                prefs.turnFinished = value
                Task { await model.setPrefs(entry.id, prefs) }
            }
        }
        rowDivider
        settingRow("Needs you", hint: "A permission, a question or a plan is waiting.") {
            deliveryMenu(device.prefs.needsYou) { value in
                var prefs = device.prefs
                prefs.needsYou = value
                Task { await model.setPrefs(entry.id, prefs) }
            }
        }
        if let reminders = entry.reminders {
            reminderRows(entry, reminders)
        }
        rowDivider
        settingRow("Critical alerts", hint: "A session you marked critical needs you.") {
            Toggle("", isOn: Binding(get: { device.prefs.critical }, set: { on in
                var prefs = device.prefs
                prefs.critical = on
                Task { await model.setPrefs(entry.id, prefs) }
            }))
            .labelsHidden()
            .tint(Theme.accent)
        }
        rowDivider
        settingRow("Errors", hint: "An error broke a session.") {
            Toggle("", isOn: Binding(get: { device.prefs.errors }, set: { on in
                var prefs = device.prefs
                prefs.errors = on
                Task { await model.setPrefs(entry.id, prefs) }
            }))
            .labelsHidden()
            .tint(Theme.accent)
        }
        rowDivider
        actionRow(entry.testing ? "Sending…" : "Send test push", systemImage: "paperplane") {
            Task { await model.sendTest(entry.id, servers: store.servers) }
        }
        .disabled(entry.testing)
        ForEach(entry.testResults) { result in
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(result.ok ? Theme.accent : Theme.danger)
                Text(verbatim: result.ok ? "Apple accepted the test push for \(result.name)."
                     : (result.error ?? "The test push failed."))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let error = entry.saveError {
            Text(verbatim: error)
                .font(.caption)
                .foregroundStyle(Theme.danger)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        rowDivider
        settingRow("Device", hint: LocalizedStringKey("\(device.name) · \(device.environment) · \(device.tokenHint)")) {
            EmptyView()
        }
    }

    // MARK: - Reminders

    /// The server's reminders of an item still waiting: on/off, when, how
    /// often after that, and quiet hours. They apply to every device of the
    /// server and to the desktop.
    @ViewBuilder
    private func reminderRows(_ entry: NotificationsSettingsModel.Entry,
                              _ reminders: PendingReminderSettings) -> some View {
        let save: (PendingReminderSettings) -> Void = { model.setReminders(entry.id, $0) }
        rowDivider
        settingRow("Reminders", hint: "Remind me again while a question, permission or plan is still waiting. For every device of this server.") {
            Toggle("", isOn: Binding(get: { reminders.enabled }, set: { on in
                var next = reminders
                next.enabled = on
                save(next)
            }))
            .labelsHidden()
            .tint(Theme.accent)
        }
        if reminders.enabled {
            rowDivider
            settingRow("Remind after") {
                choiceMenu(current: reminders.stepsSecs, choices: PendingReminderSettings.stepPresets,
                           title: ReminderText.steps) { steps in
                    var next = reminders
                    next.stepsSecs = steps
                    save(next)
                }
            }
            rowDivider
            settingRow("Then every") {
                choiceMenu(current: reminders.repeatSecs, choices: PendingReminderSettings.repeatPresets,
                           title: ReminderText.repeating) { secs in
                    var next = reminders
                    next.repeatSecs = secs
                    save(next)
                }
            }
            rowDivider
            settingRow("Quiet hours", hint: quietHint(reminders)) {
                Toggle("", isOn: Binding(get: { reminders.quietHours }, set: { on in
                    var next = reminders
                    next.quietHours = on
                    save(next)
                }))
                .labelsHidden()
                .tint(Theme.accent)
            }
            if reminders.quietHours {
                rowDivider
                settingRow("From") {
                    DatePicker("", selection: ReminderText.time(reminders.quietStartMin) { minutes in
                        var next = reminders
                        next.quietStartMin = minutes
                        save(next)
                    }, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                }
                rowDivider
                settingRow("Until") {
                    DatePicker("", selection: ReminderText.time(reminders.quietEndMin) { minutes in
                        var next = reminders
                        next.quietEndMin = minutes
                        save(next)
                    }, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                }
            }
        }
        if let error = entry.remindersError {
            Text(verbatim: error)
                .font(.caption)
                .foregroundStyle(Theme.danger)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func quietHint(_ reminders: PendingReminderSettings) -> LocalizedStringKey {
        let zone = reminders.timezone
        if !zone.isEmpty, zone != TimeZone.current.identifier {
            return "Reminders due then wait for the end. Saved in \(zone)."
        }
        return "Reminders due then wait for the end."
    }

    private func choiceMenu<Value: Hashable>(current: Value, choices: [Value], title: @escaping (Value) -> String,
                                             set: @escaping (Value) -> Void) -> some View {
        Menu {
            ForEach(choices, id: \.self) { choice in
                Button {
                    set(choice)
                } label: {
                    if choice == current {
                        Label(title(choice), systemImage: "checkmark")
                    } else {
                        Text(verbatim: title(choice))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: title(current))
                    .font(.subheadline)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Theme.accent)
        }
    }

    // MARK: - Controls

    private func deliveryMenu(_ current: PushDelivery, set: @escaping (PushDelivery) -> Void) -> some View {
        Menu {
            ForEach(PushDelivery.allCases, id: \.self) { option in
                Button {
                    set(option)
                } label: {
                    if option == current {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(verbatim: option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: current.title)
                    .font(.subheadline)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Theme.accent)
        }
    }

    @ViewBuilder
    private func settingRow<Trailing: View>(
        _ title: LocalizedStringKey,
        hint: LocalizedStringKey? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionRow(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rowDivider: some View {
        Divider().overlay(Theme.hairline).padding(.leading, 16)
    }
}

/// Loads and edits this iPhone's device row on each saved server.
@MainActor
@Observable
final class NotificationsSettingsModel {
    enum LoadState: Equatable {
        case loading
        case loaded
        case notRegistered
        case failed(String)
    }

    struct Entry: Identifiable {
        let profile: ServerProfile
        var state: LoadState = .loading
        var device: PushDeviceView?
        var testResults: [TestPushResult] = []
        var testing = false
        var saveError: String?
        /// The server's reminder settings; nil on a server without them.
        var reminders: PendingReminderSettings?
        var remindersError: String?
        var id: UUID { profile.id }
    }

    private(set) var entries: [Entry] = []

    func load(servers: [ServerProfile]) async {
        // Keep loaded rows while refreshing; add new servers, drop removed ones.
        entries = servers.map { profile in
            entries.first(where: { $0.id == profile.id }) ?? Entry(profile: profile)
        }
        await withTaskGroup(of: Void.self) { group in
            for profile in servers {
                group.addTask { await self.reload(profile.id, servers: servers) }
            }
        }
    }

    func reload(_ id: UUID, servers: [ServerProfile]) async {
        guard let profile = servers.first(where: { $0.id == id }) else { return }
        guard let client = ServerStore.makeClient(for: profile) else {
            update(id) { $0.state = .failed("This server's token is missing.") }
            return
        }
        do {
            let devices = try await client.listPushDevices()
            let recorded = PushServerIndex.entry(for: id)
            let token = PushRegistration.shared.deviceToken ?? recorded?.token
            let byID = devices.first(where: { device in
                device.id == recorded?.deviceID && (token.map { device.matches(token: $0) } ?? true)
            })
            let mine = byID ?? token.flatMap { t in devices.first(where: { $0.matches(token: t) }) }
            // A server that predates the pending list has no reminders.
            let reminders = try? await client.getPendingReminderSettings()
            update(id) {
                $0.device = mine
                $0.state = mine == nil ? .notRegistered : .loaded
                $0.reminders = reminders
            }
        } catch {
            update(id) { $0.state = .failed(Self.describe(error)) }
        }
    }

    func registerNow(_ id: UUID, servers: [ServerProfile]) async {
        guard let profile = servers.first(where: { $0.id == id }) else { return }
        update(id) { $0.state = .loading }
        await PushRegistration.shared.register(with: profile)
        await reload(id, servers: servers)
    }

    func setPrefs(_ id: UUID, _ prefs: PushDevicePrefs) async {
        guard let entry = entries.first(where: { $0.id == id }), let device = entry.device,
              let client = ServerStore.makeClient(for: entry.profile) else { return }
        let previous = device.prefs
        update(id) {
            $0.device?.prefs = prefs
            $0.saveError = nil
        }
        do {
            let saved = try await client.updatePushDevicePrefs(id: device.id, prefs: prefs)
            update(id) { $0.device = saved }
        } catch {
            update(id) {
                $0.device?.prefs = previous
                $0.saveError = Self.describe(error)
            }
        }
    }

    func sendTest(_ id: UUID, servers: [ServerProfile]) async {
        guard let entry = entries.first(where: { $0.id == id }),
              let client = ServerStore.makeClient(for: entry.profile) else { return }
        update(id) {
            $0.testing = true
            $0.testResults = []
        }
        do {
            let results = try await client.sendTestPush(deviceId: entry.device?.id)
            update(id) {
                $0.testResults = results
                $0.testing = false
            }
            if results.contains(where: \.removed) { await reload(id, servers: servers) }
        } catch {
            update(id) {
                $0.testing = false
                $0.saveError = Self.describe(error)
            }
        }
    }

    /// Saves wait a moment, so turning a time wheel sends one request.
    @ObservationIgnored private var reminderSaves: [UUID: Task<Void, Never>] = [:]

    /// Show the new reminder settings at once and save them shortly, with this
    /// iPhone's time zone for the quiet hours. A failed save puts back what
    /// the server has.
    func setReminders(_ id: UUID, _ settings: PendingReminderSettings) {
        guard let entry = entries.first(where: { $0.id == id }),
              let client = ServerStore.makeClient(for: entry.profile) else { return }
        update(id) {
            $0.reminders = settings
            $0.remindersError = nil
        }
        reminderSaves[id]?.cancel()
        reminderSaves[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            var outgoing = settings
            outgoing.timezone = TimeZone.current.identifier
            do {
                let saved = try await client.updatePendingReminderSettings(outgoing)
                guard !Task.isCancelled else { return }
                self?.update(id) { $0.reminders = saved }
            } catch {
                guard !Task.isCancelled else { return }
                let stored = try? await client.getPendingReminderSettings()
                self?.update(id) {
                    if let stored { $0.reminders = stored }
                    $0.remindersError = Self.describe(error)
                }
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// How the reminder settings read.
enum ReminderText {
    /// "5 min", "2 hr", "1 day" in the app's language.
    static func duration(_ secs: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        return formatter.string(from: TimeInterval(secs)) ?? "\(secs / 60) min"
    }

    /// "5 min, 30 min, 2 hr".
    static func steps(_ steps: [Int]) -> String {
        steps.isEmpty ? String(localized: "Never") : steps.map(duration).joined(separator: ", ")
    }

    /// "4 hr", or "Never" for no repeat.
    static func repeating(_ secs: Int) -> String {
        secs <= 0 ? String(localized: "Never") : duration(secs)
    }

    /// A time of day as minutes after midnight, for a `DatePicker`.
    static func time(_ minutes: Int, set: @escaping (Int) -> Void) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: (minutes / 60) % 24, minute: minutes % 60, second: 0, of: Date())
                    ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                set((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
            }
        )
    }
}
