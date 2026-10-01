import SwiftUI

struct CardSurface: ViewModifier {
    var padding = Layout.spacing
    var color = Palette.paper
    var radius = Layout.cardRadius
    func body(content: Content) -> some View {
        content.padding(padding).background(color, in: RoundedRectangle(cornerRadius: radius))
    }
}

struct SectionHeading: View {
    let title: String
    var actionTitle: String?
    var actionSymbol: String?
    var actionIdentifier = ""
    var action: (() -> Void)?
    var body: some View {
        HStack {
            Text(title).font(BrandFont.heading).accessibilityAddTraits(.isHeader)
            if let actionTitle, let action {
                Spacer()
                Button(action: action) {
                    if let actionSymbol { Label(actionTitle, systemImage: actionSymbol) }
                    else { Text(actionTitle) }
                }.frame(minWidth: Layout.touchTarget, minHeight: Layout.touchTarget)
                    .foregroundStyle(Palette.green).accessibilityIdentifier(actionIdentifier)
                    .accessibilityLabel("\(actionTitle) \(title.lowercased())")
            }
        }
    }
}

/// A settled selection with secondary choices underneath, shared by forms/cards.
struct SelectionDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var identifier = ""
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: Layout.compact) {
            Button {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: Layout.compact) {
                    configuration.label
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.subheadline.weight(.semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 180 : 0)).foregroundStyle(Palette.muted)
                }.contentShape(Rectangle()).frame(minHeight: Layout.touchTarget)
            }.buttonStyle(.plain).accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
                .accessibilityIdentifier(identifier)
            if configuration.isExpanded {
                Divider()
                configuration.content.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct EmptyState: View {
    enum Style { case page, card }
    let symbol: String
    let title: String
    let message: String
    var style: Style = .page
    var actionTitle: String?
    var actionIdentifier = ""
    var action: (() -> Void)?
    var body: some View {
        Group {
            if style == .card { content.modifier(CardSurface(padding: Layout.cardRadius)) }
            else { content.padding(.horizontal, Layout.cardRadius).padding(.vertical, Layout.gutter * 2) }
        }
    }
    private var content: some View {
        VStack(spacing: Layout.spacing) {
            if style == .page {
                Image(systemName: symbol).font(.largeTitle).foregroundStyle(Palette.green)
                    .frame(width: Layout.iconTile, height: Layout.iconTile)
                    .background(Palette.soft(0), in: RoundedRectangle(cornerRadius: Layout.cardRadius))
                    .accessibilityHidden(true)
            } else { Image(systemName: symbol).font(.largeTitle).foregroundStyle(Palette.green).accessibilityHidden(true) }
            Text(title).font(BrandFont.heading)
            Text(message).modifier(MemoryReadingStyle()).foregroundStyle(Palette.muted)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(PrimaryButton()).accessibilityIdentifier(actionIdentifier)
            }
        }.multilineTextAlignment(.center).frame(maxWidth: .infinity)
    }
}

/// The caller owns validation, saving, and cancellation of any draft work.
struct EditorControls: ViewModifier {
    let saving: Bool
    var canSave = true
    var dismissalBlocked = false
    @Binding var error: String?
    let errorTitle: String
    var saveTitle = "Save"
    var saveIdentifier = ""
    let cancel: () -> Void
    let save: () -> Void
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel).disabled(saving) }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : saveTitle, action: save).disabled(saving || !canSave)
                    .accessibilityIdentifier(saveIdentifier)
            }
        }.interactiveDismissDisabled(saving || dismissalBlocked)
            .alert(errorTitle, isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }
}

struct DateRangeFields: View {
    @Binding var start: Date
    @Binding var end: Date
    var ongoing: Binding<Bool>?
    var components: DatePickerComponents = .date
    var endTitle = "To"
    var body: some View {
        DatePicker("From", selection: $start, in: ...Date(), displayedComponents: components)
            .onChange(of: start, initial: true) { _, value in if end < value { end = value } }
        if let ongoing { Toggle("Ongoing", isOn: ongoing) }
        if ongoing?.wrappedValue != true {
            DatePicker(endTitle, selection: $end, in: start...max(start, Date()), displayedComponents: components)
        }
    }
}

struct PermissionRow: View {
    enum Style { case inline, detailed }
    let title: String
    let status: String
    let enabled: Bool
    var style: Style = .inline
    var action: (() -> Void)?
    var body: some View {
        Group {
            if let action { Button(action: action) { label }.buttonStyle(.plain) }
            else { label }
        }.frame(minHeight: Layout.touchTarget)
    }
    @ViewBuilder private var label: some View {
        if style == .inline {
            LabeledContent {
                Text(status).foregroundStyle(Palette.muted)
            } label: { Text(title).foregroundStyle(action == nil ? Palette.ink : Palette.green) }
                .accessibilityElement(children: .combine)
        } else {
        HStack(spacing: Layout.spacing) {
            Image(systemName: enabled ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(enabled ? Palette.green : Palette.warning).font(.title2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Layout.compact) {
                Text(title).font(BrandFont.title).foregroundStyle(Palette.ink)
                Text(status).font(.subheadline).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
            if action != nil { Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted).accessibilityHidden(true) }
        }.contentShape(Rectangle()).accessibilityElement(children: .combine)
        }
    }
}
