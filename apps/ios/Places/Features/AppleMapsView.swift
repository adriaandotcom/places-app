import SwiftUI
import MapKit
import PlacesCore

// All MapKit construction lives here behind the appropriate live consent gate.
struct PrivacyMapView: View {
    @Environment(AppModel.self) private var model
    var items: [TimelineItem]?
    var routePoints: [RoutePoint]?
    var body: some View {
        if model.mapsEnabled {
            AppleMapSurface(items: items ?? model.timeline, routePoints: routePoints ?? model.routePoints)
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
    let routePoints: [RoutePoint]
    @State private var selectedPlace: Place?
    @State private var camera: MapCameraPosition = .automatic
    private var shownPlaces: [Place] {
        let ids = Set(items.compactMap(\.placeID))
        return model.places.filter { ids.contains($0.id) }
    }
    private var unnamedStays: [TimelineItem] {
        items.filter { $0.kind == .stay && model.place(for: $0) == nil && $0.coordinate?.isValid == true }
    }
    private var shownRoutes: [TimelineItem] { items.filter { $0.kind == .journey } }
    private var endpointConnections: [TimelineItem] {
        items.filter { $0.connection != nil && ($0.kind == .gap || ($0.kind == .journey && points(for: $0).count < 2)) }
    }
    private func points(for item: TimelineItem) -> [RoutePoint] {
        routePoints.filter { $0.timestamp >= item.start && $0.timestamp <= (item.end ?? .distantFuture) }
    }
    private var framingCoordinates: [Coordinate] {
        shownPlaces.map(\.coordinate) + unnamedStays.compactMap(\.coordinate)
            + shownRoutes.flatMap { points(for: $0).map(\.coordinate) }
            + endpointConnections.flatMap { [$0.connection!.from.coordinate, $0.connection!.to.coordinate] }
    }
    var body: some View {
        Map(position: $camera) {
            ForEach(shownPlaces) { place in
                Annotation(place.name, coordinate: CLLocationCoordinate2D(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude)) {
                    Button { selectedPlace = place } label: { PlaceIcon(symbol: place.symbol, colorIndex: place.colorIndex, size: 40) }
                        .accessibilityLabel(place.name)
                }
            }
            ForEach(unnamedStays) { item in
                if let coordinate = item.coordinate {
                    Marker("Somewhere new", coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude))
                        .tint(Palette.accent(4))
                }
            }
            ForEach(shownRoutes) { item in
                let points = points(for: item)
                if points.count > 1 {
                    MapPolyline(coordinates: points.map { CLLocationCoordinate2D(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) })
                        .stroke(Palette.green, lineWidth: 4)
                }
            }
            ForEach(endpointConnections) { item in
                if let connection = item.connection {
                    let from = CLLocationCoordinate2D(latitude: connection.from.coordinate.latitude, longitude: connection.from.coordinate.longitude)
                    let to = CLLocationCoordinate2D(latitude: connection.to.coordinate.latitude, longitude: connection.to.coordinate.longitude)
                    Annotation(model.endpointName(connection.from, fallback: "Earlier location"), coordinate: from) {
                        endpointMarker("A", color: Palette.accent(1))
                    }
                    Annotation(model.endpointName(connection.to, fallback: "Later location"), coordinate: to) {
                        endpointMarker("B", color: Palette.green)
                    }
                    MapPolyline(coordinates: [from, to])
                        .stroke(Palette.muted, style: StrokeStyle(lineWidth: 3, dash: [6, 6]))
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls { MapCompass(); MapScaleView() }
        .onChange(of: framingCoordinates, initial: true) { _, coordinates in
            if Set(coordinates).count == 1, let coordinate = coordinates.first {
                let span = max(1000, (shownPlaces.map(\.radius).max() ?? 100) * 4)
                camera = .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
                    latitudinalMeters: span, longitudinalMeters: span))
            } else {
                camera = .automatic
            }
        }
        .sheet(item: $selectedPlace) { place in NavigationStack { PlaceDetail(placeID: place.id) } }
    }

    private func endpointMarker(_ letter: String, color: Color) -> some View {
        Text(letter).font(.headline.bold()).foregroundStyle(.white)
            .frame(width: 32, height: 32).background(color, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .accessibilityLabel("Endpoint \(letter)")
            .accessibilityIdentifier("endpoint-\(letter)")
    }
}

struct MapScreen: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 0) {
            if model.selectedTab == .map { PrivacyMapView(items: model.mapTimeline, routePoints: model.mapRoutePoints) }
            else { Color.clear }
            if model.mapsEnabled {
                MapDateBar().id(model.selectedDay)
            }
        }.background(Palette.background).foregroundStyle(Palette.ink).navigationTitle("Map").navigationBarTitleDisplayMode(.inline)
            .toolbar { SettingsToolbar() }
    }
}

// This wrapper checks live consent before constructing the editor's MapKit view.
struct PlaceLocationMap: View {
    @Environment(AppModel.self) private var model
    @Binding var coordinate: Coordinate?
    let radius: Double
    let colorIndex: Int
    var body: some View {
        if model.mapsEnabled {
            PlacePinSurface(coordinate: $coordinate, radius: radius, colorIndex: colorIndex)
        }
    }
}

private struct PlacePinSurface: View {
    @Binding var coordinate: Coordinate?
    let radius: Double
    let colorIndex: Int
    @State private var camera: MapCameraPosition = .automatic
    var body: some View {
        MapReader { proxy in
            Map(position: $camera) {
                if let coordinate {
                    let center = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
                    MapCircle(center: center, radius: radius).foregroundStyle(Palette.accent(colorIndex).opacity(0.18))
                        .stroke(Palette.accent(colorIndex), lineWidth: 2)
                    Annotation("Place", coordinate: center) {
                        Image(systemName: "mappin.circle.fill").font(.largeTitle)
                            .symbolRenderingMode(.palette).foregroundStyle(.white, Palette.accent(colorIndex))
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .mapControls { MapCompass(); MapScaleView() }
            .simultaneousGesture(SpatialTapGesture().onEnded { event in
                if let point = proxy.convert(event.location, from: .local) {
                    coordinate = Coordinate(latitude: point.latitude, longitude: point.longitude)
                }
            })
            .accessibilityIdentifier("place-pin-map")
            .accessibilityLabel("Place location. Tap to choose a pin, or use your current location below.")
        }
        .onAppear { centerOnPin() }
        .onChange(of: coordinate) { old, new in
            if let new, old.map({ $0.distance(to: new) > 500 }) ?? true { centerOnPin() }
        }
    }
    private func centerOnPin() {
        guard let coordinate else { return }
        camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
                                             latitudinalMeters: max(radius * 4, 1000), longitudinalMeters: max(radius * 4, 1000)))
    }
}


@MainActor
protocol PlaceRegionRequest: AnyObject {
    func result() async throws -> PlaceLocality?
    func cancel()
}

@MainActor
final class ApplePlaceLookup {
    typealias Factory = @MainActor (Coordinate) -> (any PlaceRegionRequest)?
    private let factory: Factory
    private var enabled = false
    private var generation = 0
    private var request: (any PlaceRegionRequest)?
    init(factory: @escaping Factory = { AppleRegionRequest($0) }) { self.factory = factory }
    func setEnabled(_ value: Bool) {
        enabled = value
        if !value { generation += 1; request?.cancel(); request = nil }
    }
    func lookup(_ coordinate: Coordinate) async -> PlaceLocality? {
        guard enabled, coordinate.isValid, !Task.isCancelled else { return nil }
        let expected = generation
        guard let active = factory(coordinate) else { return nil }
        request = active
        let result = try? await active.result()
        guard enabled, generation == expected, !Task.isCancelled else { return nil }
        request = nil
        return result
    }
}

@MainActor
private final class AppleRegionRequest: PlaceRegionRequest {
    let request: MKReverseGeocodingRequest
    init?(_ coordinate: Coordinate) {
        guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) else { return nil }
        self.request = request
        request.preferredLocale = Locale(identifier: "en_US")
    }
    func result() async throws -> PlaceLocality? {
        guard let address = try await request.mapItems.first?.addressRepresentations else { return nil }
        let city = address.cityName ?? "", country = address.regionName ?? ""
        guard !city.isEmpty || !country.isEmpty else { return nil }
        return PlaceLocality(city: city, country: country, source: .apple)
    }
    func cancel() { request.cancel() }
}
