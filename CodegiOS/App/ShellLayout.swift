import SwiftUI
import UIKit

/// Which shell the app shows: the tab bar (compact) or the three-column
/// split view (regular).
///
/// iPhones always get the tabs. A Plus or Pro Max iPhone reports a regular
/// width in landscape, and switching shells on that rebuilt the whole
/// hierarchy on every rotation: the open session was torn down and left (the
/// split view had no session selected), its socket closed and reopened, the
/// navigation stacks and scroll positions were lost, and the app looked like
/// a different app on its side. In landscape the tabs simply get wider.
///
/// iPads follow their width class, so a window resized narrow gets the tabs;
/// `AppModel.setLayout(compact:)` carries the open screen across that change
/// and `SessionModelStore` keeps the session's model alive through it.
enum ShellLayout {
    static func usesTabs(idiom: UIUserInterfaceIdiom, horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        if idiom == .phone { return true }
        return horizontalSizeClass == .compact
    }
}
