import SwiftUI

/// UIKit retains the moving pages until a swipe settles. SwiftUI only receives
/// the final selection, so loading metadata cannot rebuild a page mid-gesture.
struct MemoryPhotoPager: UIViewControllerRepresentable {
    let photoIDs: [String]
    @Binding var selectedID: String
    let load: (String) async throws -> Data?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIViewController(context: Context) -> MemoryPhotoPagerController { MemoryPhotoPagerController() }
    func updateUIViewController(_ controller: MemoryPhotoPagerController, context: Context) {
        controller.selectionChanged = { selectedID = $0 }
        controller.makePage = { id in AnyView(PhotoBrowserPage(id: id, active: true, load: load)) }
        controller.show(photoIDs, selected: selectedID, animated: !reduceMotion)
    }
}

final class MemoryPhotoPagerController: UIPageViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    var selectionChanged: ((String) -> Void)?
    var makePage: ((String) -> AnyView)?
    private var ids: [String] = []
    private var pages: [String: UIHostingController<AnyView>] = [:]
    private var selected: String?
    private var transitioning = false
    private var pendingSelection: (id: String, animated: Bool)?

    init() { super.init(transitionStyle: .scroll, navigationOrientation: .horizontal) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        dataSource = self; delegate = self
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "memory-photo-pager"
    }

    func show(_ ids: [String], selected id: String, animated: Bool) {
        loadViewIfNeeded()
        self.ids = ids
        // An observation refresh must not fight an interactive swipe or an
        // arrow animation. The completed gesture owns the resulting selection.
        guard selected != id else { pendingSelection = nil; return }
        if transitioning { pendingSelection = (id, animated); return }
        guard let next = page(id) else { return }
        let previous = selected.flatMap { ids.firstIndex(of: $0) }
        let index = ids.firstIndex(of: id) ?? 0
        let shouldAnimate = animated && selected != nil
        selected = id; transitioning = shouldAnimate
        setViewControllers([next], direction: index >= (previous ?? 0) ? .forward : .reverse, animated: shouldAnimate) { [weak self] _ in
            guard let self else { return }
            transitioning = false
            trimPages()
            showPendingSelection()
        }
        if !shouldAnimate { trimPages() }
    }
    private func page(_ id: String) -> UIViewController? {
        guard ids.contains(id), let makePage else { return nil }
        if let page = pages[id] { return page }
        let page = UIHostingController(rootView: makePage(id))
        page.view.backgroundColor = .clear
        pages[id] = page
        return page
    }
    private func neighbor(_ controller: UIViewController, offset: Int) -> UIViewController? {
        guard let id = pages.first(where: { $0.value === controller })?.key, let index = ids.firstIndex(of: id),
              ids.indices.contains(index + offset) else { return nil }
        return page(ids[index + offset])
    }
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? { neighbor(viewController, offset: -1) }
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? { neighbor(viewController, offset: 1) }
    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) { transitioning = true }
    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        transitioning = false
        if completed, let visible = viewControllers?.first, let id = pages.first(where: { $0.value === visible })?.key {
            selected = id
            if pendingSelection == nil { selectionChanged?(id) }
        }
        trimPages()
        showPendingSelection()
    }
    private func showPendingSelection() {
        guard let pending = pendingSelection else { return }
        pendingSelection = nil
        show(ids, selected: pending.id, animated: pending.animated)
    }
    private func trimPages() {
        guard let selected, let index = ids.firstIndex(of: selected) else { return }
        // Bound decoded photos to the visible page and immediate neighbors.
        let retained = Set(ids[max(0, index - 1)...min(ids.count - 1, index + 1)])
        pages = pages.filter { retained.contains($0.key) }
        for (id, page) in pages { page.view.accessibilityElementsHidden = id != selected }
    }
}
