import SwiftUI
import PlacesCore

struct PersonAvatar: View {
    let person: MemoryPerson
    var size: CGFloat = Layout.avatarSize
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Circle().fill(Palette.accent(person.resolvedColorIndex))
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Text(person.initials.isEmpty ? "?" : person.initials).font(.system(size: size * 0.32, weight: .semibold)).foregroundStyle(.white) }
        }.frame(width: size, height: size).clipShape(Circle())
            .onChange(of: person.avatarJPEG, initial: true) { _, data in image = data.flatMap { UIImage(data: $0) } }
            .accessibilityHidden(true)
    }
}

struct PersonAvatarGroup: View {
    @Environment(AppModel.self) private var model
    let personIDs: [String]
    var border = Palette.background
    var body: some View {
        let people = personIDs.compactMap { id in model.memories.people.first { $0.id == id } }
        if !people.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: -Layout.avatarOverlap) {
                    ForEach(people) { person in
                        NavigationLink { PersonDetail(personID: person.id) } label: {
                            PersonAvatar(person: person).overlay(Circle().stroke(border, lineWidth: Layout.avatarBorder))
                        }.buttonStyle(.plain).accessibilityLabel(person.name)
                    }
                }.padding(Layout.avatarBorder)
            }.scrollIndicators(.hidden).accessibilityIdentifier("people-avatars")
        }
    }
}

struct PersonRow: View {
    let person: MemoryPerson
    var body: some View {
        HStack(spacing: Layout.spacing) {
            PersonAvatar(person: person, size: Layout.touchTarget)
            VStack(alignment: .leading, spacing: Layout.compact) {
                Text(person.name).font(BrandFont.title).foregroundStyle(Palette.ink)
                if !person.detail.isEmpty { Text(person.detail).font(.subheadline).foregroundStyle(Palette.muted).lineLimit(2) }
            }
            Spacer(minLength: 0)
        }
    }
}

struct PeopleSelectionField: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var selection: [String]
    var body: some View {
        let people = selection.compactMap { id in model.memories.people.first { $0.id == id } }
        NavigationLink { PeoplePicker(selection: $selection) } label: {
            layout {
                Text("People")
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                if people.isEmpty { Text("Add people").foregroundStyle(Palette.muted) }
                else {
                    HStack(spacing: -Layout.avatarOverlap) {
                        ForEach(people.prefix(3)) { person in
                            PersonAvatar(person: person, size: Layout.touchTarget)
                                .overlay(Circle().stroke(Palette.paper, lineWidth: Layout.avatarBorder))
                        }
                    }
                    if people.count > 3 { Text("+\(people.count - 3)").foregroundStyle(Palette.muted) }
                }
            }.frame(minHeight: Layout.touchTarget)
        }.accessibilityLabel("People").accessibilityValue(people.isEmpty ? "Add people" : people.map(\.name).joined(separator: ", "))
    }
    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Layout.compact))
            : AnyLayout(HStackLayout(spacing: Layout.spacing))
    }
}

struct PersonMentionText: View {
    @Environment(AppModel.self) private var model
    let text: String
    var mentions: [PersonMention] = []
    @State private var selected: MemoryPerson?
    private var attributed: AttributedString {
        var result = AttributedString()
        let source = text as NSString
        var cursor = 0
        for mention in PersonMentions.valid(mentions, in: text) {
            result.append(AttributedString(source.substring(with: NSRange(location: cursor, length: mention.location - cursor))))
            var name = AttributedString(source.substring(with: mention.range))
            if model.memories.people.contains(where: { $0.id == mention.personID }) {
                name.link = URL(string: "places-person://person/\(mention.personID)")
                name.foregroundColor = Palette.green
            }
            result.append(name); cursor = mention.location + mention.length
        }
        result.append(AttributedString(source.substring(from: cursor)))
        return result
    }
    var body: some View {
        Text(attributed).modifier(MemoryReadingStyle()).textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "places-person", let person = model.memories.people.first(where: { $0.id == url.lastPathComponent }) else { return .discarded }
                selected = person; return .handled
            })
            .sheet(item: $selected) { person in NavigationStack { PersonDetail(personID: person.id).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selected = nil } } } }.environment(\.hasMainNavigation, false) }
    }
}

/// One native text editor and suggestion flow for both memory notes and person descriptions.
struct PersonMentionEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var text: String
    @Binding var mentions: [PersonMention]
    let label: String
    let identifier: String
    var excludingPersonID: String?
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var focused = false
    @State private var saving = false
    @State private var creating = false
    @State private var creationRange: NSRange?
    @State private var newName = ""
    @State private var error: String?
    @State private var epoch: Int?
    private var query: (range: NSRange, name: String)? { focused ? PersonMentions.query(in: text, selection: selection, mentions: mentions) : nil }
    var body: some View {
        VStack(alignment: .leading, spacing: Layout.compact) {
            ZStack(alignment: .topLeading) {
                NativeMentionInput(text: $text, mentions: $mentions, selection: $selection, focused: $focused, label: label, identifier: identifier)
                    .frame(height: Layout.noteEditorHeight).disabled(saving)
                if text.isEmpty { Text(label).font(BrandFont.body).foregroundStyle(Palette.muted).padding(.top, Layout.compact).padding(.leading, 4).allowsHitTesting(false) }
            }
            if let query {
                VStack(spacing: 0) {
                    ForEach(model.memories.people.filter { $0.id != excludingPersonID && (query.name.isEmpty || $0.name.localizedStandardContains(query.name)) }.prefix(5)) { person in
                        Button { insert(person, range: query.range) } label: {
                            PersonRow(person: person).padding(.vertical, Layout.compact).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("mention-\(person.id)")
                    }
                    if PersonMentions.matchingPerson(named: query.name, in: model.memories.people) == nil {
                    Button {
                        newName = query.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if newName.isEmpty { creationRange = query.range; creating = true } else { create(range: query.range) }
                    } label: {
                        Label(query.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Create person…" : "Create “\(query.name.trimmingCharacters(in: .whitespacesAndNewlines))”", systemImage: "person.badge.plus")
                            .frame(maxWidth: .infinity, minHeight: Layout.touchTarget, alignment: .leading)
                    }.accessibilityIdentifier("create-mentioned-person")
                    }
                }.disabled(saving)
            }
        }.onAppear { if epoch == nil { epoch = model.memoryEpoch } }
            .alert("Create person", isPresented: $creating) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { if let creationRange { create(range: creationRange) } }
            }
            .alert("Couldn’t add person", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
    }
    private func insert(_ person: MemoryPerson, range: NSRange) {
        let updated = PersonMentions.inserting(person, in: text, mentions: mentions, replacing: range)
        text = updated.text; mentions = updated.mentions; selection = NSRange(location: updated.caret, length: 0)
    }
    private func create(range: NSRange) {
        guard let epoch, !saving, !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let existing = PersonMentions.matchingPerson(named: newName, in: model.memories.people) {
            insert(existing, range: range); return
        }
        let person = MemoryPerson(name: newName.trimmingCharacters(in: .whitespacesAndNewlines))
        saving = true
        Task {
            do { try await model.changeMemories(epoch: epoch) { try await $0.savePerson(person) }; insert(person, range: range) }
            catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}

private struct NativeMentionInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var mentions: [PersonMention]
    @Binding var selection: NSRange
    @Binding var focused: Bool
    let label: String
    let identifier: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear; view.delegate = context.coordinator
        view.adjustsFontForContentSizeCategory = true
        view.accessibilityLabel = label; view.accessibilityIdentifier = identifier
        view.keyboardDismissMode = .interactive
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        guard view.markedTextRange == nil else { return }
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(name: "BricolageGrotesque-Regular", size: 16) ?? .systemFont(ofSize: 16))
        let paragraph = NSMutableParagraphStyle(); paragraph.lineHeightMultiple = 1.5
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(Palette.ink), .paragraphStyle: paragraph]
        let rendered = NSMutableAttributedString(string: text, attributes: attributes)
        for mention in PersonMentions.valid(mentions, in: text) { rendered.addAttribute(.foregroundColor, value: UIColor(Palette.green), range: mention.range) }
        context.coordinator.updating = true
        if view.attributedText != rendered { view.attributedText = rendered }
        view.typingAttributes = attributes
        if selection.location <= text.utf16.count, selection.length <= text.utf16.count - selection.location, view.selectedRange != selection { view.selectedRange = selection }
        context.coordinator.updating = false
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeMentionInput
        var updating = false
        init(_ parent: NativeMentionInput) { self.parent = parent }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            parent.mentions = PersonMentions.adjusted(parent.mentions, replacing: range, with: text)
            return true
        }
        func textViewDidChange(_ textView: UITextView) {
            guard !updating else { return }
            parent.text = textView.text; parent.selection = textView.selectedRange
        }
        func textViewDidChangeSelection(_ textView: UITextView) { if !updating { parent.selection = textView.selectedRange } }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.focused = true }
        func textViewDidEndEditing(_ textView: UITextView) { parent.focused = false }
    }
}
