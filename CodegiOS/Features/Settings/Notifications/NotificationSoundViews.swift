import SwiftUI
import UniformTypeIdentifiers

/// Settings › Notifications › Sounds: a row per kind of notification and one
/// for every critical session, each opening ``NotificationSoundPicker``. The
/// footer names the saved servers that keep the default sound.
struct NotificationSoundsSection: View {
    let servers: [ServerProfile]

    private var sounds: NotificationSoundStore { NotificationSoundStore.shared }
    private var push: PushRegistration { PushRegistration.shared }

    var body: some View {
        EditorSection(title: "Sounds", footer: LocalizedStringKey(footer)) {
            ForEach(Array(NotificationSoundKind.allCases.enumerated()), id: \.element) { index, kind in
                if index > 0 { SoundRowDivider() }
                link(.kind(kind), hint: kind.hint)
            }
            SoundRowDivider()
            link(.critical, hint: String(localized: "Every notification of a session you marked critical, its alerts included. A folder's or a session's own sound comes first."))
        }
    }

    private func link(_ target: NotificationSoundTarget, hint: String) -> some View {
        NavigationLink {
            NotificationSoundPicker(target: target)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: target.title)
                        .font(.body)
                        .foregroundStyle(Theme.textPrimary)
                    Text(verbatim: hint)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Text(verbatim: sounds.settings.name(of: sounds.sound(for: target)))
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: String {
        let support = push.soundSupport
        let names = { (state: NotificationSoundSupport) in
            servers.filter { support[$0.id] == state }.map(\.name)
        }
        return NotificationSoundText.footer(unsupported: names(.unsupported), partly: names(.partly))
    }
}

/// The sounds to pick from for a kind, the critical sessions, a folder or a
/// session: default (or "Use default", saying what that plays) and None,
/// the Codeg tones, the imported sounds and Import from Files. A tap picks
/// the sound and plays it.
struct NotificationSoundPicker: View {
    let target: NotificationSoundTarget

    @State private var importing = false
    @State private var converting = false
    @State private var importError: String?
    /// Said under the imported sounds after a long one was cut.
    @State private var importNote: String?
    @State private var renaming: ImportedSound?
    @State private var renameText = ""
    @State private var deleting: ImportedSound?

    private var store: NotificationSoundStore { NotificationSoundStore.shared }

    var body: some View {
        let choices = NotificationSoundChoices(target: target, settings: store.settings)
        ZStack {
            CodegBackground()
            ScrollView {
                VStack(spacing: 22) {
                    EditorSection(title: "Sound") {
                        rows(choices.top)
                    }
                    EditorSection(title: "Codeg") {
                        rows(choices.tones)
                    }
                    EditorSection(title: "Imported",
                                  footer: LocalizedStringKey(importNote ?? String(localized: "Pick any audio file: it is converted for notifications, cut to 30 seconds, and kept on this iPhone."))) {
                        rows(choices.imported)
                        if !choices.imported.isEmpty { SoundRowDivider() }
                        importRow
                    }
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(Text(verbatim: target.title))
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url): importSound(url)
            case .failure(let error): importError = error.localizedDescription
            }
        }
        .alert("Rename Sound", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let sound = renaming { store.rename(sound, to: renameText) }
                renaming = nil
            }
        }
        .alert(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let sound = deleting { store.delete(sound) }
                deleting = nil
            }
        } message: {
            Text("Notifications that play it go back to the default sound.")
        }
        .alert("Couldn’t Import the Sound", isPresented: Binding(get: { importError != nil },
                                                                 set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(verbatim: importError ?? "")
        }
    }

    private var deleteTitle: Text {
        Text("Delete “\(deleting?.name ?? "")”?")
    }

    @ViewBuilder
    private func rows(_ rows: [NotificationSoundChoices.Row]) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            if index > 0 { SoundRowDivider() }
            HStack(spacing: 0) {
                Button {
                    store.choose(row.sound, for: target)
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: row.title)
                                .font(.body)
                                .foregroundStyle(Theme.textPrimary)
                            if let subtitle = row.subtitle {
                                Text(verbatim: subtitle)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 12)
                        if row.checked {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, row.imported == nil ? 16 : 8)
                    .padding(.vertical, 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(row.checked ? .isSelected : [])
                if let sound = row.imported {
                    Menu {
                        Button {
                            renameText = sound.name
                            renaming = sound
                        } label: {
                            Label("Rename…", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            deleting = sound
                        } label: {
                            Label("Delete…", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.body)
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 13)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("More for \(sound.name)"))
                }
            }
        }
    }

    private var importRow: some View {
        Button {
            importing = true
        } label: {
            HStack(spacing: 10) {
                Label("Import from Files…", systemImage: "square.and.arrow.down")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.accent)
                Spacer(minLength: 0)
                if converting { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(converting)
    }

    /// Convert the picked file, then pick it for this target and play it.
    private func importSound(_ url: URL) {
        converting = true
        importNote = nil
        Task {
            defer { converting = false }
            do {
                let sound = try await store.importSound(from: url)
                store.choose(.file(sound.fileName), for: target)
                if sound.trimmed {
                    importNote = String(localized: "“\(sound.name)” was longer than 30 seconds: it plays its first 30.")
                }
            } catch {
                importError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// ``NotificationSoundPicker`` in a sheet, for a folder or a session.
struct NotificationSoundPickerSheet: View {
    let target: NotificationSoundTarget
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            NotificationSoundPicker(target: target)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Shows the sound picker a session row, a folder row or a session's ⋯ menu
/// asked for (``SessionActions/soundPicker``).
struct NotificationSoundSheetHost: ViewModifier {
    @Bindable var actions: SessionActions

    func body(content: Content) -> some View {
        content.sheet(item: $actions.soundPicker) { target in
            NotificationSoundPickerSheet(target: target)
        }
    }
}

/// "Notification Sound…" in a menu.
struct NotificationSoundMenuItem: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Notification Sound…", systemImage: "speaker.wave.2")
        }
    }
}

private struct SoundRowDivider: View {
    var body: some View {
        Divider().overlay(Theme.hairline).padding(.leading, 16)
    }
}
