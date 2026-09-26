import SwiftUI
import UIKit
import PlacesCore

/// UIKit owns the gesture, deceleration and cancellation. Only the history below
/// the date strip moves. The 77pt edge bands avoid stealing ordinary vertical drags.
struct TimelinePager: UIViewControllerRepresentable {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var progress: CGFloat
    let select: (TimelineItem) -> Void
    let addPlace: () -> Void

    func makeUIViewController(context: Context) -> TimelinePagerController {
        TimelinePagerController()
    }
    func updateUIViewController(_ controller: TimelinePagerController, context: Context) {
        controller.changeDay = { model.selectDay($0) }
        controller.progressChanged = { value in
            // UIKit can recenter while SwiftUI is updating this controller.
            Task { @MainActor in if progress != value { progress = value } }
        }
        controller.makePage = { day in
            AnyView(TimelineDayPage(day: day, select: select, addPlace: addPlace).environment(model))
        }
        controller.scroll.bounces = !reduceMotion
        controller.show(model.selectedDay)
    }
}

final class TimelinePagerController: UIViewController, UIScrollViewDelegate {
    let scroll = TimelinePagingScrollView()
    var changeDay: ((Date) -> Void)?
    var progressChanged: ((CGFloat) -> Void)?
    var makePage: ((Date) -> AnyView)?
    private var selectedDay: Date?
    private var days: [Date] = []
    private var pages: [Date: UIHostingController<AnyView>] = [:]
    private var width: CGFloat = 0
    private var rebuilding = false
    private var pendingDay: Date?
    private let calendar = Calendar.current

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scroll.backgroundColor = .clear
        scroll.delegate = self
        scroll.isPagingEnabled = true
        scroll.isDirectionalLockEnabled = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.accessibilityIdentifier = "timeline-pager"
        view.addSubview(scroll)
    }

    func show(_ date: Date) {
        loadViewIfNeeded()
        let day = calendar.startOfDay(for: date)
        guard selectedDay != day else { return }
        // A selected date may change while a finger is still down. Finish the
        // native interaction before applying a separate date-picker selection.
        if scroll.isDragging || scroll.isDecelerating { pendingDay = day; return }
        install(day)
    }

    private func install(_ day: Date) {
        guard let makePage else { return }
        rebuilding = true
        selectedDay = day
        let today = calendar.startOfDay(for: Date())
        days = (-1...1).compactMap { calendar.date(byAdding: .day, value: $0, to: day) }.filter { $0 <= today }
        for (date, page) in pages where !days.contains(date) {
            page.willMove(toParent: nil); page.view.removeFromSuperview(); page.removeFromParent()
            pages[date] = nil
        }
        for date in days where pages[date] == nil {
            let page = UIHostingController(rootView: makePage(date))
            page.view.backgroundColor = .clear
            addChild(page); scroll.addSubview(page.view); page.didMove(toParent: self)
            pages[date] = page
        }
        layoutPages(recenter: true)
        rebuilding = false
        progressChanged?(0)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let resized = width != view.bounds.width
        scroll.frame = view.bounds
        layoutPages(recenter: resized)
    }

    private func layoutPages(recenter: Bool) {
        width = view.bounds.width
        for (index, date) in days.enumerated() {
            pages[date]?.view.frame = CGRect(x: CGFloat(index) * width, y: 0, width: width, height: view.bounds.height)
            // Offscreen days are neither VoiceOver targets nor duplicate test rows.
            pages[date]?.view.accessibilityElementsHidden = date != selectedDay
        }
        scroll.contentSize = CGSize(width: width * CGFloat(days.count), height: view.bounds.height)
        if recenter, let selectedDay, let index = days.firstIndex(of: selectedDay) {
            scroll.setContentOffset(CGPoint(x: CGFloat(index) * width, y: 0), animated: false)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if !rebuilding, width > 0, scroll.allowsDayChange, let selectedDay, let index = days.firstIndex(of: selectedDay) {
            progressChanged?(max(-1, min(1, scroll.contentOffset.x / width - CGFloat(index))))
        }

        // Still recognize a sideways drag in the middle so it cancels a card
        // tap, but only an edge-started gesture is allowed to move the history.
        guard !rebuilding, !scroll.allowsDayChange, scroll.isDragging,
              let selectedDay, let index = days.firstIndex(of: selectedDay) else { return }
        let x = CGFloat(index) * width
        if scroll.contentOffset.x != x { scroll.contentOffset.x = x }
    }
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                  targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        if !scroll.allowsDayChange, let selectedDay, let index = days.firstIndex(of: selectedDay) {
            targetContentOffset.pointee.x = CGFloat(index) * width
        }
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settle() }
    }
    private func settle() {
        guard !rebuilding, width > 0, !days.isEmpty else { return }
        if let pendingDay {
            self.pendingDay = nil; install(pendingDay); return
        }
        let index = min(days.count - 1, max(0, Int((scroll.contentOffset.x / width).rounded())))
        let day = days[index]
        guard day != selectedDay else { return }
        install(day)
        changeDay?(day)
    }
}

final class TimelinePagingScrollView: UIScrollView {
    private(set) var allowsDayChange = true
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            let velocity = panGestureRecognizer.velocity(in: self)
            let translation = panGestureRecognizer.translation(in: self)
            let start = panGestureRecognizer.location(in: self).x - translation.x - bounds.minX
            let edge: CGFloat = 77
            guard abs(velocity.x) > abs(velocity.y) * 1.4 else { return false }
            allowsDayChange = start <= edge || start >= bounds.width - edge
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

private struct TimelineDayPage: View {
    @Environment(AppModel.self) private var model
    let day: Date
    let select: (TimelineItem) -> Void
    let addPlace: () -> Void
    @State private var items: [TimelineItem] = []
    @State private var loaded = false
    @State private var failed = false
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if failed {
                    Text("This day couldn’t be loaded. Pull down to try again.").foregroundStyle(Palette.muted).padding()
                } else if !loaded {
                    ProgressView().padding()
                } else if items.isEmpty {
                    EmptyHistory(symbol: "point.topleft.down.to.point.bottomright.curvepath", title: "A little history starts here",
                        message: "Your visits and journeys will appear as you go. Add a familiar place, or enable location in Settings.")
                    Button("Add a familiar place", action: addPlace).buttonStyle(PrimaryButton())
                } else {
                    ForEach(items) { item in
                        Button { select(item) } label: { TimelineRow(item: item, place: model.place(for: item)) }
                            .buttonStyle(.plain).accessibilityIdentifier("timeline-\(item.kind.rawValue)-\(item.id)")
                    }
                }
            }.padding(.horizontal, Layout.gutter).padding(.bottom, Layout.gutter)
        }.background(Palette.background).foregroundStyle(Palette.ink)
            .refreshable { await model.refresh() }
            .task(id: model.historyRevision) {
                do {
                    let result = try await model.store?.timeline(on: day) ?? []
                    try Task.checkCancellation()
                    items = result; loaded = true; failed = false
                } catch is CancellationError { }
                catch { failed = true }
            }
    }
}
