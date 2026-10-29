import SwiftUI

/// Renders parsed unified-diff files inline: a per-file header (mode badge,
/// path, +adds / −dels) over green/red rows with dual old/new line-number
/// gutters. Pure-add files render as a clean single-gutter view (no `+` signs),
/// mirroring the codeg client's new-file presentation.
struct DiffView: View {
    let files: [DiffFile]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Position-based identity, not the models' random `UUID`s: a live edit
            // re-parses its diff on every streaming tick, and fresh UUIDs would make
            // ForEach discard and rebuild every row each tick. Parsing is
            // deterministic and append-only while streaming, so the index is stable
            // for existing rows and only newly-streamed rows get added.
            ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                DiffFileView(file: file)
            }
        }
    }
}

// MARK: - One file

private struct DiffFileView: View {
    let file: DiffFile
    /// Collapse very large diffs so a single edit can't dominate the transcript.
    var collapsedRowLimit: Int = 80

    @State private var expanded = false
    /// Where the screen offers Select Text, a long press on the file has Copy
    /// and Select Text for its diff.
    @Environment(\.selectText) private var selectText

    private enum Line: Identifiable {
        case separator(id: UUID, label: String?)
        case row(DiffRow)
        var id: UUID {
            switch self {
            case .separator(let id, _): return id
            case .row(let r): return r.id
            }
        }
    }

    private var lines: [Line] {
        var out: [Line] = []
        for (idx, hunk) in file.hunks.enumerated() {
            if idx > 0 { out.append(.separator(id: hunk.id, label: hunk.header)) }
            out.append(contentsOf: hunk.rows.map(Line.row))
        }
        return out
    }

    private var rowCount: Int { file.hunks.reduce(0) { $0 + $1.rows.count } }
    private var isLong: Bool { rowCount > collapsedRowLimit }
    private var shown: [Line] { (isLong && !expanded) ? Array(lines.prefix(collapsedRowLimit)) : lines }

    /// Width for the line-number gutter, sized to the file's widest line number so
    /// 4–5 digit numbers never clip and every row's gutters still align (a fixed
    /// 36pt clipped past ~5 digits). `mono(10)` digits advance ~6pt; pad a little.
    private var gutterWidth: CGFloat {
        let maxLine = file.hunks.reduce(0) { acc, h in
            h.rows.reduce(acc) { max($0, $1.oldLine ?? 0, $1.newLine ?? 0) }
        }
        let digits = max(2, String(maxLine).count)
        return CGFloat(digits) * 6.5 + 6
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // Position-based identity (see `DiffView.body`) — stable across
                    // the per-tick re-parse of a streaming edit.
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                        switch line {
                        case .separator(_, let label): HunkSeparator(label: label)
                        case .row(let row): DiffRowView(row: row, newFile: file.isNewFile, gutterWidth: gutterWidth)
                        }
                    }
                }
                // Size the column to its widest row so every row's full-width
                // background extends across the longest line when scrolled.
                .fixedSize(horizontal: true, vertical: false)
            }
            if isLong { expandToggle }
        }
        .background(Self.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .hairlineBorder(Theme.Radius.sm)
        .selectTextMenu(.code(file.selectableText), enabled: selectText != nil)
    }

    private var header: some View {
        HStack(spacing: 8) {
            ModeBadge(mode: file.mode)
            Text(PathFormat.short(file.path))
                .font(.mono(11))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if file.additions > 0 {
                Text("+\(file.additions)")
                    .font(Theme.Typography.microLabel.monospacedDigit()).foregroundStyle(DiffPalette.addText)
            }
            if file.deletions > 0 {
                Text("−\(file.deletions)")
                    .font(Theme.Typography.microLabel.monospacedDigit()).foregroundStyle(DiffPalette.delText)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var expandToggle: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
        } label: {
            (expanded ? Text("Show less") : Text("Show \(rowCount - collapsedRowLimit) more lines"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private static let surface = Theme.codeSurface
}

// MARK: - Row

private struct DiffRowView: View {
    let row: DiffRow
    let newFile: Bool
    let gutterWidth: CGFloat
    @Environment(\.selectText) private var selectText

    var body: some View {
        HStack(spacing: 0) {
            if !newFile { gutter(row.oldLine) }
            gutter(row.newLine)
            if !newFile {
                Text(sign)
                    .font(Theme.Typography.diffCode)
                    .foregroundStyle(signColor)
                    .frame(width: 14, alignment: .center)
            } else {
                Spacer().frame(width: 8)
            }
            Text(row.text.isEmpty ? " " : row.text)
                .font(Theme.Typography.diffCode)
                .lineSpacing(Theme.Typography.diffLineSpacing)
                .foregroundStyle(textColor)
                .modifier(SelectableText(enabled: selectText == nil))
                .padding(.trailing, 12)
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
    }

    private func gutter(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .font(Theme.Typography.diffGutter.monospacedDigit())
            .foregroundStyle(Theme.textTertiary.opacity(0.7))
            .lineLimit(1)
            .frame(width: gutterWidth, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private var sign: String {
        switch row.kind {
        case .added: return "+"
        case .deleted: return "−"
        case .context: return " "
        }
    }
    private var signColor: Color {
        switch row.kind {
        case .added: return DiffPalette.addText
        case .deleted: return DiffPalette.delText
        case .context: return Theme.textTertiary
        }
    }
    private var textColor: Color {
        switch row.kind {
        case .added: return DiffPalette.addText
        case .deleted: return DiffPalette.delText
        case .context: return Theme.textSecondary
        }
    }
    private var rowBackground: Color {
        switch row.kind {
        case .added: return DiffPalette.addBg
        case .deleted: return DiffPalette.delBg
        case .context: return .clear
        }
    }
}

private struct HunkSeparator: View {
    let label: String?

    var body: some View {
        Text(label ?? "⋯")
            .font(.mono(10))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.03))
    }
}

private struct ModeBadge: View {
    let mode: DiffFile.Mode

    var body: some View {
        Text(label)
            .font(Theme.Typography.microLabel)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(tint.opacity(0.16), in: Capsule())
    }

    private var label: LocalizedStringKey {
        switch mode {
        case .added: return "ADDED"
        case .modified: return "MODIFIED"
        case .deleted: return "DELETED"
        case .renamed: return "RENAMED"
        }
    }
    private var tint: Color {
        switch mode {
        case .added: return DiffPalette.addText
        case .modified: return Theme.accent
        case .deleted: return DiffPalette.delText
        case .renamed: return Theme.accent
        }
    }
}
