import SwiftUI
import CoreLocation
import CoreMotion
import PlacesCore

private enum OnboardingStep: Int, CaseIterable { case welcome, privacy, maps, location, motion, places, wifi, notifications, ready }
private enum PlacePreset: String, Identifiable {
    case home = "Home", work = "Work", another = ""
    var id: String { rawValue }
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = OnboardingStep.welcome
    @State private var placePreset: PlacePreset?
    @State private var locationValidation: String?
    @State private var requestedBackground = false
    private var steps: [OnboardingStep] { OnboardingStep.allCases.filter { $0 != .wifi || model.tracking.currentSSID != nil } }
    private var index: Int { steps.firstIndex(of: step) ?? 0 }
    private var primaryTitle: String {
        switch step {
        case .motion where model.tracking.motionAuthorization == .notDetermined: "Allow Motion & Fitness"
        case .notifications where model.tracking.notificationAuthorization == .notDetermined: "Enable notifications"
        case .ready: "Start my history"
        default: "Continue"
        }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 5) {
                        ForEach(steps, id: \.rawValue) { item in Capsule().fill(item.rawValue <= step.rawValue ? Palette.ink : Palette.line).frame(height: 5) }
                    }.accessibilityLabel("Step \(index + 1) of \(steps.count)")
                    content
                }.padding(Layout.gutter)
            }
            .background(Palette.background).foregroundStyle(Palette.ink)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 5) {
                    if step == .location, let locationValidation {
                        Text(locationValidation).font(.footnote).foregroundStyle(Palette.warning)
                            .accessibilityIdentifier("location-validation").padding(.bottom, Layout.compact)
                    }
                    Button(primaryTitle) { primary() }.buttonStyle(PrimaryButton()).accessibilityIdentifier("onboarding-primary")
                    if step != .ready {
                        Button(step == .welcome ? "How privacy works" : "Not now") { next() }
                            .font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                            .accessibilityIdentifier("onboarding-skip")
                    }
                }.padding(.horizontal, Layout.gutter).padding(.top, 12).padding(.bottom, 8).background(Palette.background)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if index > 0 { Button("Back", systemImage: "chevron.left") { step = steps[index - 1] }.labelStyle(.iconOnly) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if step != .ready { Button("Skip setup") { Task { await model.finishOnboarding() } }.accessibilityIdentifier("skip-setup") }
                }
            }
            .sheet(item: $placePreset) { preset in NavigationStack { PlaceEditor(suggestedName: preset.rawValue) } }
            .onChange(of: model.tracking.locationSetupReady) { _, complete in
                if complete { locationValidation = nil }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:
            VStack(spacing: 0) {
                InfoRow(symbol: "house.fill", title: "Home", subtitle: "Your familiar places", colorIndex: 0)
                    .rotationEffect(.degrees(-4)).padding(.trailing, 62)
                InfoRow(symbol: "cup.and.saucer.fill", title: "A favourite café", subtitle: "Little stops worth remembering", colorIndex: 2)
                    .rotationEffect(.degrees(3)).padding(.leading, 30)
            }.padding(.vertical, 16).accessibilityHidden(true)
            Text("Your location history, for you.").font(BrandFont.hero)
            Text("I built this because I find it useful to look back and see where I was on a particular day. I wanted something private, simple, and without a server to maintain.").font(BrandFont.body)
            Text("Places keeps your history on this iPhone. No analytics, no advertising, and no account. You choose which permissions to allow.").font(BrandFont.body).foregroundStyle(Palette.muted)
            InfoRow(symbol: "person.fill", title: "Built independently by Adriaan", subtitle: "Founder of Simple Analytics. Places is a separate personal project.", colorIndex: 0)
        case .privacy:
            Text("A private memory.\nNot a data trail.").font(BrandFont.hero)
            Text("Here’s what stays here, and what can connect.").font(BrandFont.body).foregroundStyle(Palette.muted)
            InfoRow(symbol: "iphone", title: "On this iPhone", subtitle: "Your observations, places, search, and history are stored and processed locally.")
            InfoRow(symbol: "map.fill", title: "Your choice of maps", subtitle: "Use Apple Maps, or download maps for use on this iPhone. Nothing loads until you choose.", colorIndex: 1)
            InfoRow(symbol: "lock.shield.fill", title: "No hidden connections", subtitle: "No analytics, advertising, or hosted AI. Map downloads come from GitHub; downloaded maps and your history stay on this iPhone.", colorIndex: 4)
            Text("Apple’s system location services operate under your device privacy settings. A full history export leaves the app only when you save it somewhere yourself.").font(.footnote).foregroundStyle(Palette.muted)
        case .maps:
            Text("Your map,\non your terms").font(BrandFont.hero)
            Text("Apple Maps is always up to date. On-device Maps keeps map browsing private and works without a connection.").font(BrandFont.body).foregroundStyle(Palette.muted)
            NavigationLink { MapsSettings() } label: {
                InfoRow(symbol: "map.fill", title: "Choose maps", subtitle: model.mapProvider.title, colorIndex: 1)
            }.buttonStyle(.plain).accessibilityIdentifier("onboarding-map-settings")
            Text("On-device Maps starts with a \(model.mapDownloads.pack(.world)?.sizeLabel ?? "World") download from GitHub. You can add detailed country maps later, or continue without maps.").font(.footnote).foregroundStyle(Palette.muted)
        case .location:
            HStack(spacing: Layout.spacing) {
                PlaceIcon(symbol: "location.fill", colorIndex: 1, size: 52)
                Text("Location access").font(BrandFont.heading)
            }
            Text("Record your day, even with your phone in your pocket.").font(BrandFont.body).foregroundStyle(Palette.muted)
            VStack(spacing: Layout.spacing) {
                LocationAccessRow(title: "Background location", detail: model.tracking.authorization == .authorizedAlways ? "Always allowed" : "Still needed", complete: model.tracking.authorization == .authorizedAlways)
                LocationAccessRow(title: "Precise Location", detail: model.tracking.accuracy == .fullAccuracy && model.tracking.canLocate ? "Enabled" : "Still needed", complete: model.tracking.accuracy == .fullAccuracy && model.tracking.canLocate)
            }.padding(Layout.spacing).background(Palette.paper, in: RoundedRectangle(cornerRadius: Layout.cardRadius))
            if !model.tracking.locationSetupReady {
                InlineNotice(title: "Location setup is incomplete", message: model.tracking.locationSetupMessage)
                if !model.tracking.canLocate {
                    Button(model.tracking.authorization == .notDetermined ? "Allow location" : "Open location settings") {
                        model.tracking.requestLocation()
                    }.buttonStyle(.borderedProminent).tint(Palette.controlGreen).foregroundStyle(.white).controlSize(.large)
                } else if model.tracking.authorization != .authorizedAlways {
                    Button(requestedBackground ? "Open location settings" : "Allow background location") {
                        if requestedBackground { model.tracking.openSettings() }
                        else { requestedBackground = true; model.tracking.requestLocation() }
                    }.buttonStyle(.borderedProminent).tint(Palette.controlGreen).foregroundStyle(.white).controlSize(.large)
                } else {
                    Button("Turn on Precise Location in Settings") { model.tracking.openSettings() }
                        .buttonStyle(.borderedProminent).tint(Palette.controlGreen).foregroundStyle(.white).controlSize(.large)
                }
            }
        case .motion:
            permissionHero(symbol: "figure.walk", title: "A little movement context", index: 3)
            Text("Motion helps tell walking from cycling or driving, and helps the tracker notice when movement resumes.").font(BrandFont.body)
            InfoRow(symbol: "battery.100percent", title: "Less unnecessary location work", subtitle: "Use simple movement signals when they are available.", colorIndex: 0)
            if model.tracking.motionAuthorization != .notDetermined {
                Text(model.tracking.motionAuthorization == .authorized ? "Motion access is enabled." : "Motion is unavailable. Location tracking can still work.").font(BrandFont.body)
            }
        case .places:
            Text("Places you\nalready know").font(BrandFont.hero)
            Text("Start with the places that feel like you.").font(BrandFont.body).foregroundStyle(Palette.muted)
            ForEach(model.places) { place in InfoRow(symbol: place.symbol, title: place.name, subtitle: "Saved", colorIndex: place.colorIndex) }
            if !model.places.contains(where: { $0.name.lowercased() == "home" }) {
                PlacePresetCard(title: "Home", subtitle: "Your own little corner", symbol: "house.fill", colorIndex: 0) { placePreset = .home }
                    .accessibilityIdentifier("preset-home")
            }
            if !model.places.contains(where: { $0.name.lowercased() == "work" }) {
                PlacePresetCard(title: "Work", subtitle: "Where things get done", symbol: "briefcase.fill", colorIndex: 1) { placePreset = .work }
                    .accessibilityIdentifier("preset-work")
            }
            PlacePresetCard(title: "Another place", subtitle: "A café, a gym, somewhere you love", symbol: "mappin", colorIndex: 2) { placePreset = .another }
        case .wifi:
            permissionHero(symbol: "wifi", title: "Where does this Wi-Fi live?", index: 5)
            Text("Most Wi-Fi stays in one place. Change the type if this one doesn’t.").font(BrandFont.body)
            if let network = model.networks.first(where: { $0.ssid == model.tracking.currentSSID }) {
                WiFiClassificationPicker(network: network)
            }
        case .notifications:
            permissionHero(symbol: "bell.fill", title: "Only when\nit matters", index: 2)
            Text("Places can let you know if background location access changes and your history may develop gaps. There are no daily nudges or promotional notifications.").font(BrandFont.body)
            Text("Notifications are optional. All tracking status is also available inside the app.").font(BrandFont.body).foregroundStyle(Palette.muted)
        case .ready:
            permissionHero(symbol: "checkmark", title: "Make yourself\nat home", index: 0)
            Text("Your history begins with the permissions you chose. You can change them later in Settings.").font(BrandFont.body)
            InfoRow(symbol: "location.fill", title: "Location", subtitle: model.tracking.locationStatus, colorIndex: 1)
            InfoRow(symbol: "mappin", title: "Familiar places", subtitle: "\(model.places.count) saved", colorIndex: 2)
            InfoRow(symbol: "lock.fill", title: "Storage", subtitle: "On this iPhone. Maps: \(model.mapProvider.title).")
        }
    }

    private func permissionHero(symbol: String, title: String, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            PlaceIcon(symbol: symbol, colorIndex: index, size: 76).frame(maxWidth: .infinity).padding(.vertical, 32)
                .background(Palette.soft(index), in: RoundedRectangle(cornerRadius: 28))
            Text(title).font(BrandFont.hero)
        }
    }
    private func next() {
        locationValidation = nil
        if index + 1 < steps.count { step = steps[index + 1] }
        else { Task { await model.finishOnboarding() } }
        if step == .places { model.tracking.refreshCurrentWiFi() }
    }
    private func primary() {
        switch step {
        case .location:
            guard model.tracking.locationSetupReady else {
                locationValidation = model.tracking.locationSetupMessage + " Or choose Not now."
                return
            }
            next()
        case .motion where model.tracking.motionAuthorization == .notDetermined: model.tracking.requestMotion()
        case .notifications where model.tracking.notificationAuthorization == .notDetermined:
            Task { await model.tracking.requestNotifications(); next() }
        case .ready: Task { await model.finishOnboarding() }
        default: next()
        }
    }
}

private struct LocationAccessRow: View {
    let title: String
    let detail: String
    let complete: Bool
    var body: some View {
        HStack(spacing: Layout.spacing) {
            Image(systemName: complete ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(complete ? Palette.green : Palette.warning).font(.title2)
            VStack(alignment: .leading, spacing: Layout.compact) {
                Text(title).font(BrandFont.title)
                Text(detail).font(.subheadline).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
        }.accessibilityElement(children: .combine)
    }
}

private struct PlacePresetCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let colorIndex: Int
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: Layout.spacing) {
                PlaceIcon(symbol: symbol, colorIndex: colorIndex, size: 52)
                VStack(alignment: .leading, spacing: Layout.compact) {
                    Text(title).font(BrandFont.heading)
                    Text(subtitle).font(BrandFont.body).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(Palette.accent(colorIndex))
            }.padding(Layout.gutter).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.soft(colorIndex), in: RoundedRectangle(cornerRadius: Layout.cardRadius))
                .foregroundStyle(Palette.ink)
        }.buttonStyle(.plain).accessibilityLabel("Add " + title)
    }
}
