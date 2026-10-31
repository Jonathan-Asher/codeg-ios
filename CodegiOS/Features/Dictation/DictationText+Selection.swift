import SwiftUI

/// The text field's side of ``DictationText`` (the rest is Foundation only).
extension DictationText {
    /// A text field's selection as UTF-16 offsets, or `nil` (append) when
    /// there is none or it no longer fits the text.
    static func utf16Range(of selection: TextSelection?, in text: String) -> Range<Int>? {
        guard let selection, case .selection(let range) = selection.indices,
              range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex else { return nil }
        return range.lowerBound.utf16Offset(in: text)..<range.upperBound.utf16Offset(in: text)
    }
}
