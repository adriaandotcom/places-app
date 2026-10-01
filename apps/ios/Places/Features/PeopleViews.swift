import SwiftUI
import PlacesCore

struct PeopleList: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if model.memories.people.isEmpty {
            EmptyState(symbol: "person.2", title: "The people in your memories", message: "Add someone by name, then include them in a trip or a memory.")
        }
        ForEach(model.memories.people) { person in
            NavigationLink { PersonDetail(personID: person.id) } label: {
                PersonRow(person: person).modifier(CardSurface())
            }.buttonStyle(.plain)
        }
    }
}

struct PeoplePicker: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: [String]
    @State private var name = ""
    @State private var query = ""
    @State private var saving = false
    @State private var error: String?
    @State private var epoch: Int?
    var body: some View {
        List {
            Section {
                ForEach(model.memories.people.filter { query.isEmpty || $0.name.localizedStandardContains(query) }) { person in
                    Button {
                        if selection.contains(person.id) { selection.removeAll { $0 == person.id } }
                        else { selection.append(person.id) }
                    } label: {
                        HStack {
                            PersonAvatar(person: person, size: Layout.touchTarget)
                            Text(person.name).foregroundStyle(Palette.ink)
                            Spacer()
                            if selection.contains(person.id) { Image(systemName: "checkmark").foregroundStyle(Palette.green) }
                        }.frame(minHeight: Layout.touchTarget)
                    }.accessibilityAddTraits(selection.contains(person.id) ? .isSelected : [])
                }
            }
            Section("Add someone") {
                TextField("Name", text: $name).textContentType(.name).accessibilityIdentifier("new-person-name")
                Button("Add person") {
                    guard let epoch else { return }
                    let person = MemoryPerson(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                    if let existing = PersonMentions.matchingPerson(named: person.name, in: model.memories.people) {
                        if !selection.contains(existing.id) { selection.append(existing.id) }
                        name = ""; return
                    }
                    saving = true
                    Task {
                        do {
                            try await model.changeMemories(epoch: epoch) { try await $0.savePerson(person) }
                            selection.append(person.id); name = ""
                        } catch { self.error = error.localizedDescription }
                        saving = false
                    }
                }.disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("create-memory-person")
            }
        }.searchable(text: $query).scrollContentBackground(.hidden).background(Palette.background)
            .navigationTitle("People").navigationBarTitleDisplayMode(.inline)
            .onAppear { if epoch == nil { epoch = model.memoryEpoch } }
            .alert("Couldn’t add person", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
    }
}

struct PersonDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let personID: String
    @State private var editing = false
    private var person: MemoryPerson? { model.memories.people.first { $0.id == personID } }
    var body: some View {
        ScrollView {
            if let person {
                VStack(alignment: .leading, spacing: Layout.spacing) {
                    Button { editing = true } label: { PersonAvatar(person: person, size: Layout.portraitSize) }.accessibilityLabel("Edit avatar for \(person.name)")
                    Text(person.name).font(BrandFont.hero)
                    if !person.detail.isEmpty { PersonMentionText(text: person.detail, mentions: person.mentions ?? []) }
                    let trips = model.memories.trips.filter { !$0.hidden && $0.personIDs.contains(personID) }
                    if !trips.isEmpty {
                        SectionHeading(title: "Trips together")
                        ForEach(trips) { trip in TripLink(trip: trip) }
                    }
                    let memories = model.memories.memories(involving: personID)
                    if !memories.isEmpty {
                        SectionHeading(title: "Shared memories")
                        ForEach(memories) { memory in MemoryCard(memory: memory) }
                    }
                    if trips.isEmpty && memories.isEmpty { Text("Include \(person.name) in a trip or a memory to see it here.").foregroundStyle(Palette.muted) }
                }.padding(Layout.gutter)
            }
        }.modifier(MainNavigationClearance()).background(Palette.background).foregroundStyle(Palette.ink).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Edit person", systemImage: "pencil") { editing = true } } }
            .sheet(isPresented: $editing) {
                if let person { NavigationStack { PersonEditor(person: person, onDelete: { editing = false; dismiss(); model.showPeople() }) } }
            }
    }
}

struct PersonEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var person: MemoryPerson
    @State private var saving = false
    @State private var error: String?
    @State private var deleting = false
    @State private var epoch: Int?
    var onDelete: () -> Void
    init(person: MemoryPerson = MemoryPerson(name: ""), onDelete: @escaping () -> Void = {}) {
        _person = State(initialValue: person); self.onDelete = onDelete
    }
    var body: some View {
        Form {
            Section {
                CroppedPhotoField(photo: $person.avatarJPEG, photoIDs: model.memories.avatarPhotoIDs(for: person.id),
                    suggestsFaces: true, identifier: "choose-person-avatar") {
                    PersonAvatar(person: person, size: Layout.portraitSize)
                }
            }.listRowBackground(Color.clear)
            Section {
                TextField("Name", text: $person.name).textContentType(.name).accessibilityIdentifier("person-name")
                PersonMentionEditor(text: $person.detail, mentions: Binding(get: { person.mentions ?? [] }, set: { person.mentions = $0 }), label: "A little about them…", identifier: "person-description", excludingPersonID: person.id)
            }
            if model.memories.people.contains(where: { $0.id == person.id }) {
                Section { Button("Delete person", systemImage: "trash", role: .destructive) { deleting = true }.foregroundStyle(.red) }
            }
        }.scrollContentBackground(.hidden).background(Palette.background).navigationTitle("Person").navigationBarTitleDisplayMode(.inline)
            .onAppear { if epoch == nil { epoch = model.memoryEpoch } }
            .modifier(EditorControls(saving: saving, canSave: !person.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                error: $error, errorTitle: "Couldn’t save person", cancel: { dismiss() }, save: { save() }))
            .confirmationDialog("Remove this person from your trips and memories? Notes and photos will stay.", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete person", role: .destructive) { save(deleting: true) }
            }
    }
    private func save(deleting: Bool = false) {
        guard let epoch else { return }
        var person = person; person.name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = person
        saving = true
        Task {
            do {
                try await model.changeMemories(epoch: epoch) { store in
                    if deleting { try await store.deletePerson(id: value.id) } else { try await store.savePerson(value) }
                }
                dismiss()
                if deleting { onDelete() }
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}
