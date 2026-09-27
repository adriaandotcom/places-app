import SwiftUI
import MapKit
import PlacesCore

// All MapKit construction lives here behind the appropriate live consent gate.
struct PrivacyMapView: View {
    @Environment(AppModel.self) private var model
    var items: [TimelineItem]?
    var routePoints: [RoutePoint]?
    var focusRequest: UUID?
    @State private var viewport: MapViewport?
    @State private var showMapSettings = false
    var body: some View {
        Group {
        if model.mapsEnabled {
            AppleMapSurface(items: items ?? model.timeline, routePoints: routePoints ?? model.routePoints, viewport: $viewport, focusRequest: focusRequest)
                .accessibilityIdentifier("apple-map")
        } else if model.mapProvider == .onDevice {
            OfflineMapView(presentation: MapPresentation(items: items ?? model.timeline, routePoints: routePoints ?? model.routePoints, places: model.places), viewport: $viewport, focusRequest: focusRequest)
        } else {
            ScrollView {
            VStack(spacing: 18) {
                PlaceIcon(symbol: "map.fill", colorIndex: 1, size: 56)
                Text("A map, on your terms").font(BrandFont.heading)
                Text("Choose Apple Maps, or download maps to keep map browsing on this iPhone.")
                    .font(BrandFont.body).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                Text("Your timeline, places, and search work without it.").font(.footnote).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                Button("Choose maps") { showMapSettings = true }
                    .buttonStyle(PrimaryButton()).accessibilityIdentifier("choose-maps")
            }.padding(24).frame(maxWidth: .infinity)
            }.defaultScrollAnchor(.center, for: .alignment).background(Palette.background)
        }
        }.sheet(isPresented: $showMapSettings) {
            NavigationStack { MapsSettings().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showMapSettings = false } } } }
        }
    }
}

private struct AppleMapSurface: View {
    @Environment(AppModel.self) private var model
    let items: [TimelineItem]
    let routePoints: [RoutePoint]
    @Binding var viewport: MapViewport?
    let focusRequest: UUID?
    @State private var selectedPlace: Place?
    @State private var camera: MapCameraPosition = .automatic
    private var presentation: MapPresentation {
        MapPresentation(items: items, routePoints: routePoints, places: model.places)
    }
    var body: some View {
        Map(position: $camera) {
            ForEach(presentation.pins) { pin in
                Annotation(pin.name, coordinate: CLLocationCoordinate2D(latitude: pin.coordinate.latitude, longitude: pin.coordinate.longitude)) {
                    if let place = model.places.first(where: { $0.id == pin.placeID }) {
                        Button { selectedPlace = place } label: { PlaceIcon(symbol: pin.symbol, colorIndex: pin.colorIndex, size: 40) }
                            .accessibilityLabel(pin.name)
                    } else if let letter = pin.letter {
                        Text(letter).font(.headline.bold()).foregroundStyle(.white)
                            .frame(width: 32, height: 32).background(Palette.accent(pin.colorIndex), in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .accessibilityLabel("Endpoint \(letter)").accessibilityIdentifier("endpoint-\(letter)")
                    } else { PlaceIcon(symbol: pin.symbol, colorIndex: pin.colorIndex, size: 40).accessibilityLabel(pin.name) }
                }
            }
            ForEach(presentation.paths) { path in
                MapPolyline(coordinates: path.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                    .stroke(path.dashed ? Palette.muted : Palette.green,
                            style: StrokeStyle(lineWidth: path.dashed ? 3 : 4, dash: path.dashed ? [6, 6] : []))
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls { MapCompass(); MapScaleView() }
        .onMapCameraChange(frequency: .onEnd) { context in
            viewport = MapViewport(center: Coordinate(latitude: context.region.center.latitude, longitude: context.region.center.longitude),
                latitudeSpan: context.region.span.latitudeDelta, longitudeSpan: context.region.span.longitudeDelta)
        }
        .onAppear { frame(restoreViewport: true) }
        .onChange(of: presentation.coordinates) { _, _ in frame(restoreViewport: false) }
        .onChange(of: focusRequest) { _, _ in frame(restoreViewport: false) }
        .sheet(item: $selectedPlace) { place in NavigationStack { PlaceDetail(placeID: place.id) } }
    }
    private func frame(restoreViewport: Bool) {
        if restoreViewport, let viewport {
            camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: viewport.center.latitude, longitude: viewport.center.longitude),
                span: MKCoordinateSpan(latitudeDelta: viewport.latitudeSpan, longitudeDelta: viewport.longitudeSpan)))
        } else if let region = presentation.fittingViewport {
            camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: region.center.latitude, longitude: region.center.longitude),
                span: MKCoordinateSpan(latitudeDelta: region.latitudeSpan, longitudeDelta: region.longitudeSpan)))
        } else { camera = .automatic }
    }
}

struct MapScreen: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 0) {
            if model.selectedTab == .map { PrivacyMapView(items: model.mapTimeline, routePoints: model.mapRoutePoints, focusRequest: model.mapFocusRequest) }
            else { Color.clear }
            if model.mapsAvailable {
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
    @State private var viewport: MapViewport?
    var body: some View {
        if model.mapsEnabled {
            PlacePinSurface(coordinate: $coordinate, radius: radius, colorIndex: colorIndex, viewport: $viewport)
        } else if model.mapProvider == .onDevice {
            OfflineMapView(presentation: MapPresentation(pins: coordinate.map { [MapPin(id: "draft", name: "Place", coordinate: $0, symbol: "mappin", colorIndex: colorIndex)] } ?? [], radius: radius), viewport: $viewport, pinChanged: { coordinate = $0 })
        }
    }
}

private struct PlacePinSurface: View {
    @Binding var coordinate: Coordinate?
    let radius: Double
    let colorIndex: Int
    @State private var camera: MapCameraPosition = .automatic
    @Binding var viewport: MapViewport?
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
            .onMapCameraChange(frequency: .onEnd) { context in
                viewport = MapViewport(center: Coordinate(latitude: context.region.center.latitude, longitude: context.region.center.longitude),
                    latitudeSpan: context.region.span.latitudeDelta, longitudeSpan: context.region.span.longitudeDelta)
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
        .onAppear {
            if let viewport {
                camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: viewport.center.latitude, longitude: viewport.center.longitude),
                    span: MKCoordinateSpan(latitudeDelta: viewport.latitudeSpan, longitudeDelta: viewport.longitudeSpan)))
            } else { centerOnPin() }
        }
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
    func lookup(_ coordinate: Coordinate) async throws -> PlaceLocality? {
        guard enabled, coordinate.isValid, !Task.isCancelled else { return nil }
        let expected = generation
        guard let active = factory(coordinate) else { return nil }
        request = active
        defer { if generation == expected { request = nil } }
        let result = try await active.result()
        guard enabled, generation == expected, !Task.isCancelled else { return nil }
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
