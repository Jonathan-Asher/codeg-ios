import SwiftUI
import UIKit

// MARK: - The math

/// Scroll anchoring as plain functions: which row the reader is at, where to
/// scroll to put a row back, and how to hold a row still while the layout
/// above it changes. ``TranscriptScrollBridge`` applies them to the list.
enum ScrollAnchorMath {
    /// A row's frame in content coordinates.
    struct Row: Equatable {
        let id: String
        let minY: CGFloat
        let maxY: CGFloat
        /// A transcript row (not the top or bottom chrome row).
        var anchorable = true
        /// A persisted row: it keeps its id across reloads, so it is the
        /// better row to save.
        var persisted = true
    }

    /// The top row the reader sees: the first row, in order, that still shows
    /// below `visibleTop` and starts above `visibleBottom`. With
    /// `preferPersisted`, the first such persisted row (falling back to any).
    /// `offset` is how far `visibleTop` is below the row's top.
    static func topRow(_ rows: [Row], visibleTop: CGFloat, visibleBottom: CGFloat,
                       preferPersisted: Bool = false) -> (id: String, offset: CGFloat)? {
        let showing = rows.filter { $0.anchorable && $0.maxY > visibleTop + 0.5 && $0.minY < visibleBottom }
            .sorted { $0.minY < $1.minY }
        let pick = (preferPersisted ? showing.first(where: \.persisted) : nil) ?? showing.first
        return pick.map { ($0.id, visibleTop - $0.minY) }
    }

    /// The range a content offset may take.
    static func offsetRange(contentHeight: CGFloat, viewportHeight: CGFloat,
                            topInset: CGFloat, bottomInset: CGFloat) -> ClosedRange<CGFloat> {
        let lower = -topInset
        let upper = max(lower, contentHeight + bottomInset - viewportHeight)
        return lower...upper
    }

    static func clamp(_ y: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(y, range.lowerBound), range.upperBound)
    }

    /// The content offset that puts the visible top `offset` points below
    /// the top of a row at `rowMinY` (as far as the content allows).
    static func restoreOffsetY(rowMinY: CGFloat, offset: CGFloat, topInset: CGFloat,
                               range: ClosedRange<CGFloat>) -> CGFloat {
        clamp(rowMinY + offset - topInset, to: range)
    }

    /// The content offset that keeps a row `screenY` points below the content
    /// offset after the layout moved its top to `rowMinY`: rows inserted or
    /// grown above it push the offset down by the same amount, so nothing on
    /// screen moves.
    static func lockedOffsetY(rowMinY: CGFloat, screenY: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        clamp(rowMinY - screenY, to: range)
    }

    /// Within `screens` screen heights of the top of the content: time to
    /// bring older messages in, before the reader gets there.
    static func isNearTop(contentOffsetY: CGFloat, topInset: CGFloat, viewportHeight: CGFloat,
                          screens: CGFloat = 1.5) -> Bool {
        contentOffsetY + topInset < max(1, viewportHeight) * screens
    }
}

// MARK: - The bridge

/// What the transcript's `List` scrolls on, reached from SwiftUI: its
/// `UICollectionView`. SwiftUI's `List` has no way to say "keep this row
/// where it is" or "scroll to this row and this many points into it", so the
/// bridge does it on the collection view, inside UIKit's own layout pass:
///
/// - **Holding the reader's row still.** While the reader is scrolled up, the
///   row at the top of the screen is held at its place on screen. Whenever
///   the content size changes (older messages put in front, a picture above
///   it that loaded taller than its placeholder, a reply that re-rendered)
///   and whenever anything but the reader moves the offset, the offset is
///   set so that row is back where it was, in the same layout pass, so
///   nothing on screen jumps and no frame shows it moved.
/// - **Saving and restoring the reading position.** The row at the top and
///   how far into it, and back to exactly there.
///
/// Rows are mapped to the collection view's items by order: item `i` of the
/// list's one section is `rows[i]` (the top row, the transcript's nodes, the
/// bottom anchor). SwiftUI computes the rows (in `body`) a frame or two
/// before it gives them to the collection view, so the bridge keeps the last
/// few row lists and reads the one whose length matches the items the
/// collection view has now; with none matching it does nothing.
@MainActor
final class TranscriptScrollBridge {
    struct RowInfo: Equatable {
        let id: String
        /// The persisted turn the row belongs to (nil for live rows).
        var turnID: String?
        /// A transcript row, not chrome.
        var anchorable = true
    }

    /// Where the reader is, as saved.
    struct Anchor: Equatable {
        let id: String
        let turnID: String?
        let offset: CGFloat
    }

    /// One list of rows and where each id is in it.
    private struct RowList {
        let rows: [RowInfo]
        let index: [String: Int]
    }

    /// The rows the collection view shows now, and its section.
    private struct Applied {
        let list: RowList
        let section: Int
    }

    #if DEBUG
    /// The bridge of the transcript on screen (tests).
    static weak var current: TranscriptScrollBridge?
    #endif
    /// Off only to measure the transcript without anchoring (tests).
    static var anchoringEnabled = true
    /// SwiftUI's own size-change anchor while the reader is scrolled up
    /// (nil: none). Changed only to measure the alternatives (tests).
    static var scrolledUpSizeAnchor: UnitPoint? = nil

    #if DEBUG
    /// What the bridge saw and did, when tracing (tests).
    static var tracing = false
    private(set) var trace: [String] = []
    func clearTrace() { trace = [] }
    private func note(_ line: @autoclosure () -> String) {
        guard Self.tracing else { return }
        trace.append(String(format: "%.4f ", CACurrentMediaTime()) + line())
    }
    #else
    private func note(_ line: @autoclosure () -> String) {}
    #endif

    private func describe(_ view: UICollectionView) -> String {
        let items = view.numberOfSections > 0 ? view.numberOfItems(inSection: 0) : -1
        return "h=\(Int(view.contentSize.height)) y=\(String(format: "%.1f", view.contentOffset.y)) items=\(items) rows=\(lists.last?.rows.count ?? 0)"
    }

    private(set) weak var collectionView: UICollectionView?
    /// The latest row lists, newest last.
    private var lists: [RowList] = []
    private var sizeObservation: NSKeyValueObservation?
    private var offsetObservation: NSKeyValueObservation?
    /// A tiny view inside the collection view: UIKit lays it out right after
    /// the collection view's own layout, in the same pass, once the cells are
    /// where they will be drawn. The held row is put back there, from its
    /// cell. (UIKit moves the cells of an update before it reports the new
    /// content size, so a correction made when the size changes alone can
    /// come before the cells move, and two frames showed the jump.)
    private let hook = LayoutHook(frame: CGRect(x: 0, y: 0, width: 1, height: 1))

    /// The row held in place and its top's distance below the content offset
    /// (`rowMinY - contentOffset.y`). Absolute: whatever moved the offset in
    /// an update (UIKit and SwiftUI both touch it while applying one), the
    /// row ends at the same place. Only the reader's scroll moves it; an
    /// animated programmatic scroll releases it until it settles.
    private var lock: (id: String, screenY: CGFloat)?
    /// The content offset the last time the held row was where it belongs:
    /// where a foreign offset change goes back to while the layout is still
    /// catching up with an update.
    private var heldOffsetY: CGFloat?
    /// Items at the last layout pass that changed the content size.
    private var laidOutItems: Int?
    /// Corrections in this run loop turn (a fight is given up after a few).
    private var turnCorrections = 0
    private var turnResetScheduled = false
    /// A position to scroll to once the rows are laid out.
    private var pendingRestore: (id: String, offset: CGFloat)?
    private var adjusting = false

    /// Following the latest message: nothing is held.
    var pinned = true {
        didSet { if pinned { lock = nil } }
    }
    /// A restore landed.
    var onRestored: (() -> Void)?
    /// The reader came within 1.5 screens of the top (true) or left that zone
    /// (false); called again with true whenever the content grows while they
    /// are there. Read from the collection view itself, in the same pass as
    /// the bridge's corrections.
    var onNearTop: ((Bool) -> Void)?
    private var wasNearTop = false
    /// The test scroll stands in for the reader's finger.
    var onUserScroll: (() -> Void)?
    var onScrollSettled: (() -> Void)?

    /// A picture of the screen laid over the list while older turns go in:
    /// SwiftUI gives the collection view the new items a frame or two before
    /// it lays them out, and those frames would show the rows shifted. The
    /// picture is taken off once the held row is back in place.
    private var cover: UIView?
    private var coverLink: CADisplayLink?
    private var coverStarted: CFTimeInterval = 0
    private var coverSteadyFrames = 0
    private var coverRowCount = 0
    /// Frames the list was covered, and the longest cover (seconds).
    private(set) var coveredFrames = 0
    private(set) var longestCover: CFTimeInterval = 0
    var isCovered: Bool { cover != nil }

    /// How often the held row was put back, and the last correction (points).
    private(set) var corrections = 0
    private(set) var lastCorrection: CGFloat = 0

    // MARK: Wiring

    func attach(_ collectionView: UICollectionView) {
        guard collectionView !== self.collectionView else { return }
        self.collectionView = collectionView
        #if DEBUG
        Self.current = self
        #endif
        sizeObservation = collectionView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.contentSizeChanged() }
        }
        offsetObservation = collectionView.observe(\.contentOffset, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated { self?.contentOffsetChanged(view) }
        }
        hook.removeFromSuperview()
        collectionView.addSubview(hook)
        hook.onLayout = { [weak self] in self?.afterLayout() }
        if pendingRestore != nil { holdAfterLayout() }
    }

    /// The list's rows, in order, as the next update will show them.
    func setRows(_ newRows: [RowInfo]) {
        guard newRows != lists.last?.rows else { return }
        note("rows \(lists.last?.rows.count ?? 0) -> \(newRows.count)")
        var index: [String: Int] = [:]
        index.reserveCapacity(newRows.count)
        for (i, row) in newRows.enumerated() where index[row.id] == nil { index[row.id] = i }
        lists.append(RowList(rows: newRows, index: index))
        if lists.count > 4 { lists.removeFirst(lists.count - 4) }
    }

    /// The row list the collection view shows now: the newest one as long as
    /// its items. Nil when none is (an update half applied).
    private func applied(in view: UICollectionView) -> Applied? {
        let sections = view.numberOfSections
        guard sections > 0 else { return nil }
        for section in 0..<sections {
            let count = view.numberOfItems(inSection: section)
            if let list = lists.last(where: { $0.rows.count == count }) {
                if sections == 1 || count > 1 { return Applied(list: list, section: section) }
            }
        }
        return nil
    }

    /// The layout has caught up with the items: as many as at the last
    /// layout pass that changed the content size (an update hands the items
    /// over first and lays them out a pass or two later).
    private func layoutIsCurrent(_ view: UICollectionView, _ applied: Applied) -> Bool {
        guard let laidOut = laidOutItems else { return true }
        return view.numberOfItems(inSection: applied.section) == laidOut
    }

    // MARK: Holding

    /// Hold the row at the top of the screen where it is (after the reader's
    /// scroll moves or settles, or a programmatic scroll ends).
    func captureLock() {
        guard !pinned, let view = collectionView, let anchor = topAnchor(preferPersisted: false),
              let minY = drawnMinY(of: anchor.id) ?? frame(of: anchor.id)?.minY else { return }
        lock = (anchor.id, minY - view.contentOffset.y)
        heldOffsetY = view.contentOffset.y
    }

    /// A programmatic scroll is about to move the list: hold nothing until it settles.
    func releaseLock() {
        note("release")
        lock = nil
        heldOffsetY = nil
    }

    private func contentSizeChanged() {
        hook.setNeedsLayout()
        if let view = collectionView, view.numberOfSections > 0 {
            laidOutItems = view.numberOfItems(inSection: applied(in: view)?.section ?? 0)
        }
        holdAfterLayout()
        checkNearTop(again: true)
    }

    private func contentOffsetChanged(_ view: UICollectionView) {
        guard !adjusting else { return }
        note("offset \(describe(view)) tracking=\(view.isTracking) lock=\(lock?.id ?? "-")")
        if view.isTracking || view.isDecelerating {
            // The reader's own scrolling moves what is held, and shows the list.
            endCover()
            captureLock()
        } else if lock != nil, pendingRestore == nil {
            // Not the reader: SwiftUI or UIKit applying an update. The row
            // stays where it is, once the cells are laid out.
            hook.setNeedsLayout()
        }
        checkNearTop(again: false)
    }

    private func checkNearTop(again: Bool) {
        guard let view = collectionView, let onNearTop, view.contentSize.height > 0 else { return }
        let near = ScrollAnchorMath.isNearTop(contentOffsetY: view.contentOffset.y,
                                              topInset: view.adjustedContentInset.top,
                                              viewportHeight: view.bounds.height)
        guard near != wasNearTop || (near && again) else { return }
        wasNearTop = near
        onNearTop(near)
    }

    private func holdAfterLayout() {
        guard let view = collectionView else { return }
        note("size \(describe(view)) lock=\(lock?.id ?? "-") pinned=\(pinned)")
        if let pending = pendingRestore {
            if apply(pending, to: view) {
                pendingRestore = nil
                let done = onRestored
                onRestored = nil
                // The rows around the target settle their heights over the next
                // passes, and SwiftUI may still place its own first offset: look
                // again for a few frames, then show the list.
                settleRestore(pending, checks: 3, then: done)
            }
            return
        }
        hold(view, revertWhileStale: false)
    }

    /// Put the held row back at its place on screen. While the collection
    /// view's layout hasn't caught up with its items yet (SwiftUI moves the
    /// offset as it hands over an update), an offset set by someone else goes
    /// back to where the row was last held, until the layout is there.
    private func hold(_ view: UICollectionView, revertWhileStale: Bool) {
        guard Self.anchoringEnabled, !pinned, let lock else { return }
        guard let applied = applied(in: view), layoutIsCurrent(view, applied),
              let frame = frame(of: lock.id, in: applied, view: view) else {
            if revertWhileStale, let held = heldOffsetY, abs(view.contentOffset.y - held) > 0.25 {
                note("hold: layout catching up, offset back to \(Int(held))")
                set(view, offsetY: held)
            } else {
                note("hold skipped (\(describe(view)))")
            }
            return
        }
        let target = ScrollAnchorMath.lockedOffsetY(rowMinY: frame.minY, screenY: lock.screenY, range: range(of: view))
        let delta = target - view.contentOffset.y
        note("hold \(lock.id) minY=\(Int(frame.minY)) screenY=\(Int(lock.screenY)) target=\(Int(target)) delta=\(Int(delta))")
        if abs(delta) > 0.25 {
            set(view, offsetY: target)
            lastCorrection = delta
        }
        heldOffsetY = target
    }

    // MARK: Covering an update

    /// Lay a picture of the screen over the list until the update that is
    /// about to change its rows (`expectedRows` of them) is laid out and the
    /// held row is back where it was.
    func coverUpdate(expectedRows: Int) {
        guard Self.anchoringEnabled, cover == nil, let view = collectionView, let host = view.superview,
              view.window != nil, let picture = view.snapshotView(afterScreenUpdates: false) else { return }
        captureLock()
        picture.frame = view.frame
        picture.isUserInteractionEnabled = false
        host.insertSubview(picture, aboveSubview: view)
        cover = picture
        coverRowCount = expectedRows
        coverSteadyFrames = 0
        coverStarted = CACurrentMediaTime()
        let link = CADisplayLink(target: CoverTicker(self), selector: #selector(CoverTicker.tick))
        link.add(to: .main, forMode: .common)
        coverLink = link
        note("cover for \(expectedRows) rows")
    }

    fileprivate func coverTick() {
        guard cover != nil, let view = collectionView else { return endCover() }
        coveredFrames += 1
        let elapsed = CACurrentMediaTime() - coverStarted
        var steady = false
        if let applied = applied(in: view), applied.list.rows.count == coverRowCount,
           laidOutItems == coverRowCount {
            if let lock, let minY = drawnMinY(of: lock.id) ?? frame(of: lock.id)?.minY {
                let target = ScrollAnchorMath.lockedOffsetY(rowMinY: minY, screenY: lock.screenY, range: range(of: view))
                if abs(target - view.contentOffset.y) > 0.5 { set(view, offsetY: target) } else { steady = true }
            } else {
                steady = lock == nil
            }
        }
        coverSteadyFrames = steady ? coverSteadyFrames + 1 : 0
        if coverSteadyFrames >= 2 || elapsed > 0.6 { endCover() }
    }

    func endCover() {
        guard let picture = cover else { return }
        longestCover = max(longestCover, CACurrentMediaTime() - coverStarted)
        coverLink?.invalidate()
        coverLink = nil
        picture.removeFromSuperview()
        cover = nil
        note("uncover")
    }

    /// After the collection view's layout, in the same pass: put the held row
    /// back from where its cell is.
    private func afterLayout() {
        guard Self.anchoringEnabled, !pinned, pendingRestore == nil, let lock, let view = collectionView,
              let minY = drawnMinY(of: lock.id) ?? frame(of: lock.id)?.minY else { return }
        let target = ScrollAnchorMath.lockedOffsetY(rowMinY: minY, screenY: lock.screenY, range: range(of: view))
        let delta = target - view.contentOffset.y
        note("after layout \(lock.id) drawnMinY=\(Int(minY)) target=\(Int(target)) delta=\(Int(delta))")
        guard abs(delta) > 0.25 else { return }
        set(view, offsetY: target)
        heldOffsetY = target
        lastCorrection = delta
    }

    /// Where row `id`'s cell is (content coordinates), when it is on screen.
    private func drawnMinY(of id: String) -> CGFloat? {
        guard let view = collectionView, let applied = applied(in: view),
              let index = applied.list.index[id],
              let cell = view.cellForItem(at: IndexPath(item: index, section: applied.section)) else { return nil }
        return cell.frame.minY
    }

    /// Set the offset as the bridge (not the reader), a few times a turn at most.
    private func set(_ view: UICollectionView, offsetY: CGFloat) {
        turnCorrections += 1
        if !turnResetScheduled {
            turnResetScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.turnCorrections = 0
                self?.turnResetScheduled = false
            }
        }
        guard turnCorrections <= 8 else {
            note("hold: given up for this turn")
            return
        }
        adjusting = true
        view.contentOffset.y = offsetY
        adjusting = false
        corrections += 1
    }

    // MARK: Position

    /// The row at the top of the screen and how far into it.
    func topAnchor(preferPersisted: Bool) -> Anchor? {
        guard let view = collectionView, let applied = applied(in: view) else { return nil }
        let rows = applied.list.rows
        let top = view.contentOffset.y + view.adjustedContentInset.top
        let bottom = view.contentOffset.y + view.bounds.height - view.adjustedContentInset.bottom
        let candidates: [ScrollAnchorMath.Row] = view.indexPathsForVisibleItems
            .filter { $0.section == applied.section && $0.item < rows.count }
            .compactMap { path in
                guard let frame = view.layoutAttributesForItem(at: path)?.frame else { return nil }
                let row = rows[path.item]
                return ScrollAnchorMath.Row(id: row.id, minY: frame.minY, maxY: frame.maxY,
                                            anchorable: row.anchorable, persisted: row.turnID != nil)
            }
        guard let pick = ScrollAnchorMath.topRow(candidates, visibleTop: top, visibleBottom: bottom,
                                                 preferPersisted: preferPersisted) else { return nil }
        return Anchor(id: pick.id, turnID: rows[applied.list.index[pick.id] ?? 0].turnID, offset: pick.offset)
    }

    /// Scroll so the visible top is `offset` points into row `id`, now if
    /// the rows are laid out, else as soon as they are.
    func restore(id: String, offset: CGFloat) {
        pendingRestore = (id, offset)
        lock = nil
        if let view = collectionView, view.contentSize.height > 0 { holdAfterLayout() }
    }

    var isRestorePending: Bool { pendingRestore != nil }

    func cancelRestore() {
        pendingRestore = nil
        onRestored = nil
    }

    /// Put the restored row back where it belongs if anything moved it since,
    /// `checks` times a few frames apart, then call `done`.
    private func settleRestore(_ target: (id: String, offset: CGFloat), checks: Int, then done: (() -> Void)?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let view = self.collectionView else {
                done?()
                return
            }
            if !self.pinned, let frame = self.frame(of: target.id) {
                let want = ScrollAnchorMath.restoreOffsetY(rowMinY: frame.minY, offset: target.offset,
                                                           topInset: view.adjustedContentInset.top,
                                                           range: self.range(of: view))
                if abs(view.contentOffset.y - want) > 0.5 { self.set(view, offsetY: want) }
                self.lock = (target.id, frame.minY - want)
                self.heldOffsetY = want
            }
            if checks > 1 {
                self.settleRestore(target, checks: checks - 1, then: done)
            } else {
                done?()
            }
        }
    }

    private func apply(_ target: (id: String, offset: CGFloat), to view: UICollectionView) -> Bool {
        guard view.contentSize.height > 0, let frame = frame(of: target.id) else { return false }
        let y = ScrollAnchorMath.restoreOffsetY(rowMinY: frame.minY, offset: target.offset,
                                                topInset: view.adjustedContentInset.top, range: range(of: view))
        set(view, offsetY: y)
        lock = (target.id, frame.minY - y)
        heldOffsetY = y
        return true
    }

    // MARK: Geometry

    /// A row's frame in content coordinates, nil while no row list matches
    /// the collection view's items.
    func frame(of id: String) -> CGRect? {
        guard let view = collectionView, let applied = applied(in: view) else { return nil }
        return frame(of: id, in: applied, view: view)
    }

    private func frame(of id: String, in applied: Applied, view: UICollectionView) -> CGRect? {
        guard let index = applied.list.index[id] else { return nil }
        return view.layoutAttributesForItem(at: IndexPath(item: index, section: applied.section))?.frame
    }

    /// Where row `id` starts below the visible top (negative when above it).
    func screenY(of id: String) -> CGFloat? {
        guard let view = collectionView, let frame = frame(of: id) else { return nil }
        return frame.minY - view.contentOffset.y - view.adjustedContentInset.top
    }

    private func range(of view: UICollectionView) -> ClosedRange<CGFloat> {
        ScrollAnchorMath.offsetRange(contentHeight: view.contentSize.height, viewportHeight: view.bounds.height,
                                     topInset: view.adjustedContentInset.top,
                                     bottomInset: view.adjustedContentInset.bottom)
    }

    #if DEBUG
    /// Scroll as the reader would (tests): let go of the bottom, move the
    /// list, and settle there.
    func scrollAsUser(toY y: CGFloat) {
        guard let view = collectionView else { return }
        onUserScroll?()
        pinned = false
        // A finger moves the hold with it, frame by frame.
        lock = nil
        heldOffsetY = nil
        view.contentOffset.y = ScrollAnchorMath.clamp(y, to: range(of: view))
        view.layoutIfNeeded()
        captureLock()
        onScrollSettled?()
    }

    /// The cell showing row `id` now (tests: what is on screen, as drawn).
    func cell(for id: String) -> UICollectionViewCell? {
        guard let view = collectionView, let applied = applied(in: view),
              let index = applied.list.index[id] else { return nil }
        return view.cellForItem(at: IndexPath(item: index, section: applied.section))
    }

    func scrollAsUser(by dy: CGFloat) {
        guard let view = collectionView else { return }
        scrollAsUser(toY: view.contentOffset.y + dy)
    }
    #endif
}

/// Drives the cover's checks without the display link holding the bridge.
private final class CoverTicker: NSObject {
    weak var bridge: TranscriptScrollBridge?
    init(_ bridge: TranscriptScrollBridge) { self.bridge = bridge }
    @MainActor @objc func tick() { bridge?.coverTick() }
}

/// See ``TranscriptScrollBridge``'s `hook`.
private final class LayoutHook: UIView {
    var onLayout: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        alpha = 0
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

// MARK: - Finding the collection view

/// A zero-size probe that finds the `UICollectionView` behind the
/// transcript's `List`: the one it sits in (as a row's background), or, as
/// the list's own background, the one covering it.
struct TranscriptCollectionFinder: UIViewRepresentable {
    let found: (UICollectionView) -> Void

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.found = found
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.found = found
        probe.searchSoon()
    }

    final class Probe: UIView {
        var found: ((UICollectionView) -> Void)?
        private weak var match: UICollectionView?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            searchSoon()
        }

        func searchSoon() {
            guard match == nil || match?.window == nil else { return }
            DispatchQueue.main.async { [weak self] in self?.search() }
        }

        private func search() {
            guard let window, match == nil || match?.window == nil else { return }
            // Inside a row: the list's own collection view is an ancestor.
            var ancestor = superview
            while let view = ancestor {
                if let list = view as? UICollectionView {
                    adopt(list)
                    return
                }
                ancestor = view.superview
            }
            // Beside the list: the collection view covering the probe the most,
            // looked for from the nearest ancestor outward.
            let target = convert(bounds, to: window)
            var level = superview
            while let root = level {
                if let list = Self.coveringCollectionView(under: root, target: target, window: window, skipping: self) {
                    adopt(list)
                    return
                }
                level = root.superview
            }
        }

        private func adopt(_ list: UICollectionView) {
            match = list
            found?(list)
        }

        private static func coveringCollectionView(under root: UIView, target: CGRect, window: UIWindow,
                                                   skipping probe: UIView) -> UICollectionView? {
            var best: (view: UICollectionView, area: CGFloat)?
            var queue: [UIView] = [root]
            var index = 0
            while index < queue.count {
                let view = queue[index]
                index += 1
                if view === probe { continue }
                if let list = view as? UICollectionView {
                    let frame = list.convert(list.bounds, to: window).intersection(target)
                    let area = frame.isNull ? 0 : frame.width * frame.height
                    if area > 0, area > (best?.area ?? 0) { best = (list, area) }
                    // A list inside a row of this one is not the transcript.
                    continue
                }
                queue.append(contentsOf: view.subviews)
            }
            return best?.view
        }
    }
}
