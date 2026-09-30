import SwiftUI
import UIKit
import Observation

/// A short-lived toast and a session undo stack. Callers retain only the data
/// needed to restore their own deletion; no Photos-library deletion is involved.
@MainActor @Observable final class DeleteUndo {
    private struct Entry { let id = UUID(); let title: String; let restore: @MainActor () async throws -> Void }
    private var entries: [Entry] = []
    private(set) var toastID: UUID?
    private(set) var working = false
    var error: String?
    var title: String? { entries.last?.title }
    var canUndo: Bool { !entries.isEmpty && !working }
    func register(_ title: String, restore: @escaping @MainActor () async throws -> Void) {
        entries.append(Entry(title: title, restore: restore))
        if entries.count > 20 { entries.removeFirst() }
        toastID = UUID()
    }
    func hideToast() { toastID = nil }
    func clear() { entries = []; toastID = nil; error = nil }
    func undo() async {
        guard !working, let entry = entries.last else { return }
        working = true
        do { try await entry.restore(); entries.removeAll { $0.id == entry.id }; toastID = nil }
        catch { self.error = "Couldn’t undo that deletion. Please try again." }
        working = false
    }
}

struct DeleteUndoPresentation: ViewModifier {
    let undo: DeleteUndo
    var enabled = true
    @Environment(\.hasMainNavigation) private var hasNavigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmUndo = false
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if enabled, undo.toastID != nil, let title = undo.title {
                HStack(spacing: Layout.spacing) {
                    Text(title).font(.subheadline)
                    Spacer(minLength: Layout.compact)
                    Button("Undo") { Task { await undo.undo() } }
                        .font(.subheadline.weight(.semibold)).frame(minHeight: Layout.touchTarget)
                        .disabled(!undo.canUndo).accessibilityIdentifier("undo-delete")
                }.padding(.horizontal, Layout.spacing).foregroundStyle(Palette.ink)
                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: Layout.cardRadius))
                    .overlay { RoundedRectangle(cornerRadius: Layout.cardRadius).stroke(Palette.line) }
                    .padding(.horizontal, Layout.gutter)
                    .padding(.bottom, hasNavigation ? Layout.navigationIslandHeight + Layout.spacing : Layout.compact)
                    .transition(.opacity)
            }
        }.animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: undo.toastID)
            .task(id: undo.toastID) {
                guard enabled, undo.toastID != nil else { return }
                do { try await Task.sleep(for: .seconds(6)); undo.hideToast() } catch { }
            }
            .background(UndoShakeReceiver(enabled: enabled && undo.canUndo) { confirmUndo = true }.frame(width: 0, height: 0))
            .alert("Undo deletion?", isPresented: $confirmUndo) {
                Button("Undo") { Task { await undo.undo() } }
                Button("Cancel", role: .cancel) { }
            }
            .alert("Couldn’t undo", isPresented: Binding(get: { undo.error != nil }, set: { if !$0 { undo.error = nil } })) {
                Button("OK") { undo.error = nil }
            } message: { Text(undo.error ?? "") }
    }
}

struct UndoShakeReceiver: UIViewControllerRepresentable {
    let enabled: Bool
    let shake: () -> Void
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.enabled = enabled; controller.shake = shake
        if enabled { controller.claimWhenVisible() }
        else { controller.resignFirstResponder() }
    }
    final class Controller: UIViewController {
        var enabled = false
        var shake: (() -> Void)?
        override var canBecomeFirstResponder: Bool { enabled }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); claimWhenVisible() }
        override func viewWillDisappear(_ animated: Bool) { resignFirstResponder(); super.viewWillDisappear(animated) }
        func claimWhenVisible() {
            guard enabled, let window = viewIfLoaded?.window else { return }
            var ancestor = parent
            while let controller = ancestor {
                if controller.presentedViewController != nil { return }
                ancestor = controller.parent
            }
            func editing(_ view: UIView) -> Bool {
                if view.isFirstResponder, view is UITextInput { return true }
                return view.subviews.contains(where: editing)
            }
            if !editing(window) { becomeFirstResponder() }
        }
        override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
            if motion == .motionShake, enabled { shake?() }
            else { super.motionEnded(motion, with: event) }
        }
    }
}

/// The same action supports native Form/List rows and cards in a ScrollView.
/// Partial drags reveal Delete; a full swipe commits when the caller supports it.
struct SwipeToDelete: ViewModifier {
    var nativeRow = false
    var allowsFullSwipe = true
    var enabled = true
    var title = "Delete"
    let delete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    @State private var start: CGFloat = 0
    @State private var width: CGFloat = 320
    private var actionWidth: CGFloat { Layout.touchTarget * 2 }
    func body(content: Content) -> some View {
        if nativeRow {
            content.swipeActions(edge: .trailing, allowsFullSwipe: allowsFullSwipe) {
                if enabled { Button(title, systemImage: "trash", action: delete).tint(.red) }
            }
        } else {
            content.offset(x: offset)
                .background(alignment: .trailing) {
                    if offset < 0 {
                        Color.red.overlay(alignment: .trailing) {
                            Button(action: commit) {
                                Label(title, systemImage: "trash").labelStyle(.iconOnly).font(.title3)
                                    .frame(width: max(actionWidth, -offset)).frame(maxHeight: .infinity)
                                    .foregroundStyle(.white).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel(title)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Layout.cardRadius))
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { width = $0 })
                .gesture(DeletePan(enabled: enabled, open: offset < 0) { recognizer in
                    switch recognizer.state {
                    case .began: start = offset
                    case .changed: offset = min(0, max(-width, start + recognizer.translation(in: recognizer.view).x))
                    case .ended:
                        let projected = offset + recognizer.velocity(in: recognizer.view).x * 0.12
                        if allowsFullSwipe && (-offset > width * 0.65 || (-offset > actionWidth && -projected > width * 0.85)) { commit() }
                        else { settle(projected < -actionWidth * 0.5 ? -actionWidth : 0) }
                    case .cancelled, .failed: settle(0)
                    default: break
                    }
                })
                .accessibilityAction(named: title, delete)
        }
    }
    private func settle(_ value: CGFloat) { withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) { offset = value } }
    private func commit() { settle(0); delete() }
}

private struct DeletePan: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let open: Bool
    let changed: (UIPanGestureRecognizer) -> Void
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }
    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1; recognizer.delegate = context.coordinator
        return recognizer
    }
    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = enabled; context.coordinator.open = open
    }
    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) { changed(recognizer) }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var open = false
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let speed = pan.velocity(in: pan.view)
            return abs(speed.x) > abs(speed.y) * 1.4 && (speed.x < 0 || open)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer && other.view is UIScrollView
        }
    }
}
