import SwiftUI
import CoreLocation
import CoreMotion
import PlacesCore

private enum OnboardingStep: Int, CaseIterable { case welcome, privacy, location, motion, places, wifi, notifications, ready }

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = OnboardingStep.welcome
    @State private var addingPlace = false
    @State private var suggestedName = ""
    private var steps: [OnboardingStep] { OnboardingStep.allCases.filter { $0 != .wifi || model.tracking.currentSSID != nil } }
    private var index: Int { steps.firstIndex(of: step) ?? 0 }
    private var primaryTitle: String {
        switch step {
        case .location where model.tracking.authorization == .notDetermined: "Enable location"
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
            .sheet(isPresented: $addingPlace) { NavigationStack { PlaceEditor(suggestedName: suggestedName) } }
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
            InfoRow(symbol: "map.fill", title: "Apple Maps, only if you choose", subtitle: "Maps make requests to Apple. Nothing loads until you explicitly enable them.", colorIndex: 1)
            InfoRow(symbol: "lock.shield.fill", title: "No hidden connections", subtitle: "No analytics, advertising, third-party services, or hosted AI. History is excluded from automatic device backups.", colorIndex: 4)
            Text("Apple’s system location services operate under your device privacy settings. A full history export leaves the app only when you save it somewhere yourself.").font(.footnote).foregroundStyle(Palette.muted)
        case .location:
            permissionHero(symbol: "location.fill", title: "Know where your day takes you", index: 1)
            Text("Location lets Places record journeys and recognize when you stop. Background access helps your history continue when you put your phone away.").font(BrandFont.body)
            InfoRow(symbol: "location.circle", title: "Current access", subtitle: model.tracking.locationStatus, colorIndex: 1)
            if model.tracking.authorization == .authorizedWhenInUse {
                Button("Allow background location") { model.tracking.requestLocation() }.buttonStyle(.borderedProminent)
                Text("You can keep foreground-only access. Your history will have gaps while Places is closed.").font(.footnote).foregroundStyle(Palette.muted)
            } else if model.tracking.authorization == .denied || model.tracking.authorization == .restricted {
                Button("Open location settings") { model.tracking.openSettings() }.buttonStyle(.bordered)
            }
            Text("Precise Location helps distinguish nearby places. Battery use adapts automatically; there is no accuracy mode to manage.").font(BrandFont.body).foregroundStyle(Palette.muted)
        case .motion:
            permissionHero(symbol: "figure.walk", title: "A little movement context", index: 3)
            Text("Motion helps tell walking from cycling or driving, and helps the tracker notice when movement resumes.").font(BrandFont.body)
            InfoRow(symbol: "battery.100percent", title: "Less unnecessary location work", subtitle: "Use simple movement signals when they are available.", colorIndex: 0)
            if model.tracking.motionAuthorization != .notDetermined {
                Text(model.tracking.motionAuthorization == .authorized ? "Motion access is enabled." : "Motion is unavailable. Location tracking can still work.").font(BrandFont.body)
            }
        case .places:
            Text("Places you\nalready know").font(BrandFont.hero)
            Text("Give your usual stops a name. You can add their Wi-Fi names too; they become evidence only when your location agrees.").font(BrandFont.body).foregroundStyle(Palette.muted)
            ForEach(model.places) { place in InfoRow(symbol: place.symbol, title: place.name, subtitle: place.address.isEmpty ? "Saved on this iPhone" : place.address, colorIndex: place.colorIndex) }
            HStack {
                Button("Add Home", systemImage: "house") { suggestedName = "Home"; addingPlace = true }
                Spacer()
                Button("Add Work", systemImage: "briefcase") { suggestedName = "Work"; addingPlace = true }
            }.buttonStyle(.bordered).controlSize(.large)
            Button("Add another place") { suggestedName = ""; addingPlace = true }.frame(minHeight: 44)
        case .wifi:
            permissionHero(symbol: "wifi", title: "Where does this Wi-Fi live?", index: 5)
            Text(model.tracking.currentSSID ?? "Current Wi-Fi unavailable").font(BrandFont.heading)
            Text("When this network and your location agree, Places can learn it automatically. Shared networks and portable hotspots need different treatment.").font(BrandFont.body)
            if let network = model.networks.first(where: { $0.ssid == model.tracking.currentSSID }) {
                WiFiClassificationPicker(network: network)
            }
            Text("You can manage saved networks in Settings at any time.").font(.footnote).foregroundStyle(Palette.muted)
        case .notifications:
            permissionHero(symbol: "bell.fill", title: "Only when\nit matters", index: 2)
            Text("Places can let you know if background location access changes and your history may develop gaps. There are no daily nudges or promotional notifications.").font(BrandFont.body)
            Text("Notifications are optional. All tracking status is also available inside the app.").font(BrandFont.body).foregroundStyle(Palette.muted)
        case .ready:
            permissionHero(symbol: "checkmark", title: "Make yourself\nat home", index: 0)
            Text("Your history begins with the permissions you chose. You can change them later in Settings.").font(BrandFont.body)
            InfoRow(symbol: "location.fill", title: "Location", subtitle: model.tracking.locationStatus, colorIndex: 1)
            InfoRow(symbol: "mappin", title: "Familiar places", subtitle: "\(model.places.count) saved", colorIndex: 2)
            InfoRow(symbol: "lock.fill", title: "Storage", subtitle: "On this iPhone. Apple Maps is off.")
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
        if index + 1 < steps.count { step = steps[index + 1] }
        else { Task { await model.finishOnboarding() } }
        if step == .places { model.tracking.refreshCurrentWiFi() }
    }
    private func primary() {
        switch step {
        case .location where model.tracking.authorization == .notDetermined: model.tracking.requestLocation()
        case .motion where model.tracking.motionAuthorization == .notDetermined: model.tracking.requestMotion()
        case .notifications where model.tracking.notificationAuthorization == .notDetermined:
            Task { await model.tracking.requestNotifications(); next() }
        case .ready: Task { await model.finishOnboarding() }
        default: next()
        }
    }
}
