import Foundation

/// The open session's model is the session Talk drives (``TalkSessionPort``):
/// it has every member under the name the port uses, but the title.
extension SessionDetailViewModel: TalkSessionPort {
    var talkTitle: String? { summary?.trimmedTitle }
}
