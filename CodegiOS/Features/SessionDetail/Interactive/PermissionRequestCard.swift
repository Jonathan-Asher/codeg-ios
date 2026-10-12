import SwiftUI

/// The inline approval card for a `permission_request` — and for ExitPlanMode,
/// whose proposed plan renders in the body. Pinned above the compose bar while
/// the agent is blocked. Mirrors codeg web's `permission-dialog.tsx`: a header,
/// a contextual body (command / diff / plan / allowed actions / web / raw), and
/// the agent-supplied option buttons (filled to allow, bordered to reject).
struct PermissionRequestCard: View {
    let pending: PendingPermission
    /// Set once the session's mode changed while this card waited (switching
    /// to Bypass permissions mid-turn, say): the request was made before the
    /// switch and the agent still waits for an answer to it, as on the desktop.
    var modeNote: String? = nil
    /// Resolve with the chosen `option_id`. Returns true on success — the model
    /// then clears the card; false keeps it and re-enables the buttons.
    let onRespond: (String) async -> Bool

    @State private var submittingOptionId: String?
    @State private var failed = false

    private var parsed: ParsedPermission { pending.parsed }

    /// Long bodies (diffs, plan prose, many entries) get a height-capped scroll;
    /// short ones render inline so the card stays compact.
    private var bodyScrolls: Bool {
        !parsed.diffFiles.isEmpty || parsed.planMarkdown != nil
            || parsed.planEntries.count > 4 || parsed.allowedPrompts.count > 4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if bodyScrolls {
                ScrollView { bodyContent }
                    .frame(maxHeight: 300)
            } else {
                bodyContent
            }

            if let modeNote {
                Label { Text(verbatim: modeNote) } icon: { Image(systemName: "arrow.triangle.swap") }
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if failed {
                Label("Couldn’t submit. Please try again.", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
            }

            VStack(spacing: 8) {
                ForEach(pending.options) { option in
                    optionButton(option)
                }
            }
        }
        .padding(14)
        .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .hairlineBorder(Theme.Radius.lg)
        .shadow(color: .black.opacity(0.14), radius: 12, y: 3)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: parsed.isPlan ? "list.bullet.clipboard" : "exclamationmark.shield.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: parsed.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text(parsed.isPlan
                     ? "The agent wants to proceed with this plan."
                     : "The agent needs permission to continue.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !parsed.isPlan, !parsed.kind.isEmpty {
                Text(verbatim: parsed.kind)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .lineLimit(1)
            }
        }
    }

    // MARK: Body

    @ViewBuilder
    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let command = parsed.command {
                section("Command", "terminal") {
                    CodeBlockView(code: command, language: "bash")
                    if let cwd = parsed.cwd {
                        Text(verbatim: "cwd: \(cwd)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }

            if !parsed.diffFiles.isEmpty {
                DiffView(files: parsed.diffFiles)
            }

            if let plan = parsed.planMarkdown {
                section("Plan", "doc.text") {
                    MarkdownContent(raw: plan)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surfaceNested, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                }
            } else if !parsed.planEntries.isEmpty {
                section("Plan", "checklist") {
                    // The same checklist the live plan renders — so the proposed
                    // plan the user is approving reads exactly like the plan that
                    // streams once they do (not streaming here: a steady marker).
                    PlanChecklist(items: parsed.planEntries.map(\.checklistItem))
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surfaceNested, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                }
            }

            if !parsed.allowedPrompts.isEmpty {
                section("Allowed actions", "checkmark.seal") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(parsed.allowedPrompts.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 6) {
                                if !item.tool.isEmpty {
                                    Text(verbatim: item.tool)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(Theme.textSecondary)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color.primary.opacity(0.06), in: Capsule())
                                }
                                Text(verbatim: item.prompt)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            if let mode = parsed.modeTarget {
                Label { Text("Target mode: \(mode)") } icon: { Image(systemName: "arrow.triangle.swap") }
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            if parsed.url != nil || parsed.query != nil || parsed.prompt != nil {
                section("Web", "globe") {
                    VStack(alignment: .leading, spacing: 4) {
                        if let url = parsed.url {
                            Text(verbatim: url).font(.caption.monospaced()).foregroundStyle(Theme.textPrimary)
                        }
                        if let query = parsed.query {
                            Text(verbatim: query).font(.subheadline).foregroundStyle(Theme.textPrimary)
                        }
                        if let prompt = parsed.prompt {
                            Text(verbatim: prompt).font(.subheadline).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if !parsed.hasStructuredBody {
                CodeBlockView(code: parsed.jsonPreview, language: "json")
            }
        }
    }

    private func section<Content: View>(_ label: LocalizedStringKey, _ icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            content()
        }
    }

    // MARK: Option buttons

    private func optionButton(_ option: PermissionOption) -> some View {
        Button {
            Task { await tap(option) }
        } label: {
            HStack(spacing: 6) {
                if submittingOptionId == option.optionId {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(option.isReject ? Theme.textPrimary : Theme.onAccent)
                }
                Text(verbatim: option.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .foregroundStyle(option.isReject ? Theme.textPrimary : Theme.onAccent)
            .background(
                option.isReject ? AnyShapeStyle(Color.primary.opacity(0.06)) : AnyShapeStyle(Theme.accent),
                in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
            )
            .overlay {
                if option.isReject {
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(submittingOptionId != nil)
        .opacity(submittingOptionId != nil && submittingOptionId != option.optionId ? 0.5 : 1)
    }

    private func tap(_ option: PermissionOption) async {
        guard submittingOptionId == nil else { return }
        submittingOptionId = option.optionId
        failed = false
        let ok = await onRespond(option.optionId)
        // On success the model removes the card; on failure re-enable + flag.
        if !ok {
            failed = true
            submittingOptionId = nil
        }
    }
}
