import SwiftUI
import MapKit
import PlacesCore

// This is the only file permitted to construct MapKit UI. No snapshots, searches,
// geocoders, tile preloaders, or hidden maps exist elsewhere in the application.
struct PrivacyMapView: View {
    @Environment(AppModel.self) private var model
    var items: [TimelineItem]?
    var body: some View {
        if model.mapsEnabled {
            AppleMapSurface(items: items ?? model.timeline)
                .accessibilityIdentifier("apple-map")
        } else {
            ScrollView {
            VStack(spacing: 18) {
                PlaceIcon(symbol: "map.fill", colorIndex: 1, size: 56)
                Text("A map, on your terms").font(BrandFont.heading)
                Text("Apple Maps loads map data from Apple. Your map view can reveal the area you’re looking at. Enable it only if you’re comfortable with those requests.")
                    .font(BrandFont.body).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                Text("Your timeline, places, and search work without it.").font(.footnote).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                Button("Enable Apple Maps") { Task { await model.setMapsEnabled(true) } }
                    .buttonStyle(PrimaryButton()).accessibilityIdentifier("enable-apple-maps")
            }.padding(24).frame(maxWidth: .infinity)
            }.defaultScrollAnchor(.center, for: .alignment).background(Palette.background)
        }
    }
}

private struct AppleMapSurface: View {
    @Environment(AppModel.self) private var model
    let items: [TimelineItem]
    @State private var selectedPlace: Place?
    private var shownPlaces: [Place] {
        let ids = Set(items.compactMap(\.placeID))
        return ids.isEmpty ? model.places : model.places.filter { ids.contains($0.id) }
    }
    var body: some View {
        Map {
            ForEach(shownPlaces) { place in
                Annotation(place.name, coordinate: CLLocationCoordinate2D(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude)) {
                    Button { selectedPlace = place } label: { PlaceIcon(symbol: place.symbol, colorIndex: place.colorIndex, size: 40) }
                        .accessibilityLabel(place.name)
                }
            }
            ForEach(items.filter { $0.kind == .journey }) { item in
                let points = model.routePoints.filter { $0.timestamp >= item.start && $0.timestamp <= (item.end ?? .distantFuture) }
                if points.count > 1 {
                    MapPolyline(coordinates: points.map { CLLocationCoordinate2D(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) })
                        .stroke(Palette.green, lineWidth: 4)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls { MapCompass(); MapScaleView() }
        .sheet(item: $selectedPlace) { place in NavigationStack { PlaceDetail(placeID: place.id) } }
    }
}

struct MapScreen: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 0) {
            if model.selectedTab == .map { PrivacyMapView() }
            else { Color.clear }
            if model.mapsEnabled {
                VStack(spacing: 8) {
                    Text(model.selectedDay.formatted(date: .abbreviated, time: .omitted)).font(BrandFont.title)
                    Text("Routes connect recorded samples. Unknown intervals have no route.").font(.caption).foregroundStyle(Palette.muted)
                    Button("Turn off Apple Maps") { Task { await model.setMapsEnabled(false) } }.font(.footnote).frame(minHeight: 44)
                        .accessibilityIdentifier("disable-apple-maps")
                }.padding(.horizontal, 20).padding(.top, 12).frame(maxWidth: .infinity).background(Palette.paper)
            }
        }.background(Palette.background).foregroundStyle(Palette.ink).navigationTitle("Map").navigationBarTitleDisplayMode(.inline)
            .toolbar { SettingsToolbar() }
    }
}
