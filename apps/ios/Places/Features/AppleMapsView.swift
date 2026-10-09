import SwiftUI
import MapKit
import PlacesCore

struct MapPreviewCard: View {
    @Environment(AppModel.self) private var model
    let items: [TimelineItem]
    var routePoints: [RoutePoint]?
    var caption: String?
    var body: some View {
        if model.mapsAvailable && items.contains(where: { $0.kind != .gap || $0.connection != nil }) {
            VStack(alignment: .leading, spacing: Layout.compact) {
                PrivacyMapView(items: items, routePoints: routePoints).frame(height: Layout.mapHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Layout.cardRadius))
                if let caption { Text(caption).font(.caption).foregroundStyle(Palette.muted) }
            }
        }
    }
}

struct RecordedLocationPreview: View {
    private let presentation: MapPresentation
    @State private var viewport: MapViewport?

    init(coordinate: Coordinate, accuracy: Double?) {
        let presentation = MapPresentation(recordedCoordinate: coordinate, accuracy: accuracy)
        self.presentation = presentation
        // Restore this tight framing on both renderers, including on-device maps
        // whose usual single-place view shows the surrounding neighbourhood.
        _viewport = State(initialValue: presentation.fittingViewport)
    }

    var body: some View {
        PrivacyMapView(customPresentation: presentation, retainedViewport: $viewport)
            .frame(height: Layout.mapHeight)
            .clipShape(RoundedRectangle(cornerRadius: Layout.cardRadius))
    }
}

// All MapKit construction lives here behind the appropriate live consent gate.
struct PrivacyMapView: View {
    @Environment(AppModel.self) private var model
    var items: [TimelineItem]?
    var routePoints: [RoutePoint]?
    var focusRequest: UUID?
    var customPresentation: MapPresentation?
    var chromeInsets = EdgeInsets()
    var retainedViewport: Binding<MapViewport?>?
    var rawPointSelected: ((RawMapPoint) -> Void)?
    @State private var localViewport: MapViewport?
    private var viewport: Binding<MapViewport?> { retainedViewport ?? $localViewport }
    @State private var showMapSettings = false
    var body: some View {
        Group {
        if model.mapsEnabled {
            AppleMapSurface(items: items ?? model.timeline, routePoints: routePoints ?? model.routePoints, viewport: viewport, focusRequest: focusRequest, customPresentation: customPresentation, chromeInsets: chromeInsets, rawPointSelected: rawPointSelected)
                .accessibilityIdentifier("apple-map")
        } else if model.mapProvider == .onDevice {
            OfflineMapView(presentation: customPresentation ?? MapPresentation(items: items ?? model.timeline, routePoints: routePoints ?? model.routePoints, places: model.places), viewport: viewport, focusRequest: focusRequest, chromeInsets: chromeInsets, rawPointSelected: rawPointSelected)
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
    var customPresentation: MapPresentation?
    let chromeInsets: EdgeInsets
    let rawPointSelected: ((RawMapPoint) -> Void)?
    @State private var selectedPin: MapPin?
    @State private var camera: MapCameraPosition = .automatic
    @State private var hasFramed = false
    private var presentation: MapPresentation {
        customPresentation ?? MapPresentation(items: items, routePoints: routePoints, places: model.places)
    }
    var body: some View {
        Map(position: $camera) {
            PlaceAreaOverlay(areas: presentation.areas, colorIndex: presentation.pins.first?.colorIndex ?? 0,
                customColorHex: presentation.pins.first?.customColorHex)
            if let pin = presentation.pins.first, let radius = presentation.radius {
                MapCircle(center: pin.coordinate.mapCoordinate, radius: radius)
                    .foregroundStyle(Palette.accent(pin.colorIndex, hex: pin.customColorHex).opacity(0.18))
                    .stroke(Palette.accent(pin.colorIndex, hex: pin.customColorHex), lineWidth: 2)
            }
            ForEach(presentation.pins) { pin in
                if pin.isRecordedLocation {
                    Marker(pin.name, coordinate: pin.coordinate.mapCoordinate)
                        .tint(Palette.accent(pin.colorIndex)).annotationTitles(.hidden)
                } else {
                    Annotation(pin.name, coordinate: CLLocationCoordinate2D(latitude: pin.coordinate.latitude, longitude: pin.coordinate.longitude)) {
                        if pin.unnamedStay != nil || model.places.contains(where: { $0.id == pin.placeID }) {
                            Button { selectedPin = pin } label: { PlaceIcon(symbol: pin.symbol, colorIndex: pin.colorIndex, customColorHex: pin.customColorHex, photoJPEG: pin.photoJPEG, size: 40) }
                                .accessibilityLabel(pin.name)
                                .accessibilityIdentifier("map-place-\(pin.id)")
                        } else if let letter = pin.letter {
                            Text(letter).font(.headline.bold()).foregroundStyle(Palette.iconInk(pin.colorIndex, hex: pin.customColorHex))
                                .frame(width: 32, height: 32).background(Palette.accent(pin.colorIndex, hex: pin.customColorHex), in: Circle())
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                                .accessibilityLabel("Endpoint \(letter)").accessibilityIdentifier("endpoint-\(letter)")
                        } else { PlaceIcon(symbol: pin.symbol, colorIndex: pin.colorIndex, customColorHex: pin.customColorHex, photoJPEG: pin.photoJPEG, size: 40).accessibilityLabel(pin.name) }
                    }
                }
            }
            ForEach(presentation.paths) { path in
                MapPolyline(coordinates: path.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                    .stroke(path.colorIndex.map { Palette.accent($0) } ?? (path.dashed ? Palette.muted : Palette.green),
                            style: StrokeStyle(lineWidth: path.dashed ? 3 : 4, dash: path.dashed ? [6, 6] : []))
            }
            ForEach(presentation.rawPoints) { point in
                Annotation("", coordinate: point.coordinate.mapCoordinate) {
                    Button { rawPointSelected?(point) } label: {
                        Circle().fill(Palette.accent(point.colorIndex))
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .frame(width: 14, height: 14)
                            .frame(width: Layout.touchTarget, height: Layout.touchTarget)
                            .contentShape(Circle())
                    }.buttonStyle(.plain).accessibilityLabel(point.accessibilityLabel)
                        .accessibilityIdentifier("raw-map-point-\(point.number)")
                }.annotationTitles(.hidden)
            }
        }
        .safeAreaPadding(chromeInsets)
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls { MapCompass(); MapScaleView() }
        .onMapCameraChange(frequency: .onEnd) { context in
            guard hasFramed else { return }
            viewport = MapViewport(center: Coordinate(latitude: context.region.center.latitude, longitude: context.region.center.longitude),
                latitudeSpan: context.region.span.latitudeDelta, longitudeSpan: context.region.span.longitudeDelta)
        }
        .onAppear { frame(restoreViewport: true); hasFramed = true }
        .onChange(of: presentation.coordinates) { _, _ in frame(restoreViewport: false) }
        .onChange(of: focusRequest) { _, _ in frame(restoreViewport: false) }
        .sheet(item: $selectedPin) { MapPlaceDestination(pin: $0) }
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

struct MapPlaceDestination: View {
    let pin: MapPin
    var body: some View {
        NavigationStack {
            if let placeID = pin.placeID {
                PlaceDetail(placeID: placeID)
            } else if let stay = pin.unnamedStay {
                PlaceEditor(coordinate: stay.coordinate, assigning: stay)
            }
        }.environment(\.hasMainNavigation, false)
    }
}

struct MapScreen: View {
    @Environment(AppModel.self) private var model
    @State private var settings = false
    @State private var periodHeight: CGFloat = 60
    @State private var selectedRawPoint: RawMapPoint?
    @State private var changingMode = false
    @State private var collectors = false
    var body: some View {
        GeometryReader { geometry in
            VStack {
                HStack {
                    Spacer()
                    Button { settings = true } label: {
                        Image(systemName: "slider.horizontal.3").frame(width: Layout.touchTarget, height: Layout.touchTarget)
                    }.buttonStyle(.glass).buttonBorderShape(.circle)
                        .accessibilityLabel("Settings").accessibilityIdentifier("open-settings")
                }.padding(.horizontal, Layout.gutter).padding(.top, Layout.compact)
                Spacer()
                if model.mapsAvailable {
                    HStack(spacing: Layout.compact) {
                        Button {
                            changingMode = true
                            Task { await model.setNerdMode(!model.nerdMode); changingMode = false }
                        } label: {
                            Image(systemName: model.nerdMode ? "eye.circle.fill" : "eye.circle")
                                .font(.title3).foregroundStyle(Palette.green)
                                .frame(width: Layout.touchTarget, height: Layout.touchTarget)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(changingMode)
                            .accessibilityLabel("Nerd mode").accessibilityIdentifier("map-nerd-mode")
                            .accessibilityValue(model.nerdMode ? "On" : "Off")
                        if model.nerdMode {
                            Button { collectors = true } label: {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                    .font(.title3).frame(width: Layout.touchTarget, height: Layout.touchTarget)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("Location collectors")
                                .accessibilityIdentifier("map-collectors")
                            if let raw = model.mapRawPresentation {
                                Button { selectedRawPoint = raw.rawPoints.first } label: {
                                    Text(raw.rawPoints.isEmpty ? "No raw points" : "\(raw.rawPoints.count) raw points")
                                        .font(.caption.weight(.medium)).padding(.horizontal, Layout.compact)
                                        .frame(minHeight: Layout.touchTarget)
                                }.buttonStyle(.glass).disabled(raw.rawPoints.isEmpty)
                                    .accessibilityIdentifier("raw-map-count")
                            } else { ProgressView().accessibilityLabel("Loading raw points") }
                        }
                        Spacer(minLength: 0)
                    }.padding(.leading, Layout.gutter).padding(.trailing, 48)
                    MapDateBar().id(model.selectedDay).padding(.horizontal, Layout.gutter)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { periodHeight = $0 }
                }
            }
            .padding(.bottom, Layout.navigationIslandHeight + Layout.compact)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if model.selectedTab == .map {
                    let request = model.mapFocusRequest
                    PrivacyMapView(items: model.mapTimeline, routePoints: model.mapRoutePoints, focusRequest: model.mapFocusRequest,
                        customPresentation: model.nerdMode ? model.mapRawPresentation ?? MapPresentation(pins: []) : nil,
                        chromeInsets: EdgeInsets(top: geometry.safeAreaInsets.top + Layout.touchTarget + Layout.spacing,
                            leading: 0, bottom: geometry.safeAreaInsets.bottom + Layout.navigationIslandHeight + periodHeight + Layout.spacing
                                + (model.mapsEnabled && model.nerdMode ? Layout.touchTarget + Layout.compact : 0), trailing: 0),
                        retainedViewport: Binding(get: { model.mapViewport }, set: { model.rememberMapViewport($0, for: request) }),
                        rawPointSelected: { selectedRawPoint = $0 })
                        .ignoresSafeArea()
                }
            }
        }.background(Palette.background).foregroundStyle(Palette.ink)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $settings) { NavigationStack { SettingsView() } }
            .sheet(isPresented: $collectors) {
                NavigationStack { LocationCollectorsView().toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { collectors = false } }
                } }
            }
            .sheet(item: $selectedRawPoint) { point in
                RawMapPointDetail(points: model.mapRawPresentation?.rawPoints ?? [], initialID: point.id)
                    .presentationDetents([.medium, .large])
            }
            .onChange(of: model.mapFocusRequest) { _, _ in selectedRawPoint = nil }
            .onChange(of: model.nerdMode) { _, _ in selectedRawPoint = nil }
    }
}

// The same editor surface and geometry are used by both providers.
struct PlaceLocationMap: View {
    @Environment(AppModel.self) private var model
    @Binding var coordinate: Coordinate?
    let radius: Double
    let colorIndex: Int
    var customColorHex: String?
    var name = "Place"
    var area: PlaceArea?
    var drawing: [Coordinate] = []
    var focusRequest: UUID?
    var onTap: ((Coordinate) -> Void)?
    @State private var viewport: MapViewport?
    private var presentation: MapPresentation {
        var value = MapPresentation(pins: coordinate.map { [MapPin(id: "draft", name: name, coordinate: $0, symbol: "mappin", colorIndex: colorIndex, customColorHex: customColorHex)] } ?? [], radius: area == nil && onTap == nil ? radius : nil)
        value.areas = area.map { [$0] } ?? []
        if !drawing.isEmpty {
            value.pins = drawing.enumerated().map { MapPin(id: "corner-\($0.offset)", name: "", coordinate: $0.element, symbol: "circle.fill", colorIndex: colorIndex, customColorHex: customColorHex, letter: String($0.offset + 1)) }
            value.paths = [MapPath(id: "drawing", coordinates: drawing, dashed: false)]
        }
        return value
    }
    private func tapped(_ point: Coordinate) {
        if let onTap { onTap(point) }
        else if area == nil { coordinate = point }
    }
    var body: some View {
        if model.mapsEnabled {
            PlacePinSurface(presentation: presentation, colorIndex: colorIndex, customColorHex: customColorHex, viewport: $viewport, focusRequest: focusRequest, tapped: tapped)
        } else if model.mapProvider == .onDevice {
            OfflineMapView(presentation: presentation, viewport: $viewport, focusRequest: focusRequest, pinChanged: tapped)
        }
    }
}

private struct PlacePinSurface: View {
    let presentation: MapPresentation
    let colorIndex: Int
    var customColorHex: String?
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 70, longitudeDelta: 140)))
    @Binding var viewport: MapViewport?
    let focusRequest: UUID?
    let tapped: (Coordinate) -> Void
    var body: some View {
        MapReader { proxy in
            Map(position: $camera) {
                PlaceAreaOverlay(areas: presentation.areas, colorIndex: colorIndex, customColorHex: customColorHex)
                if let coordinate = presentation.pins.first?.coordinate, let radius = presentation.radius {
                    MapCircle(center: coordinate.mapCoordinate, radius: radius).foregroundStyle(Palette.accent(colorIndex, hex: customColorHex).opacity(0.18))
                        .stroke(Palette.accent(colorIndex, hex: customColorHex), lineWidth: 2)
                }
                ForEach(presentation.paths) { path in
                    MapPolyline(coordinates: path.coordinates.map(\.mapCoordinate)).stroke(Palette.accent(colorIndex, hex: customColorHex), lineWidth: 2)
                }
                ForEach(presentation.pins) { pin in
                    Annotation(pin.name, coordinate: pin.coordinate.mapCoordinate) {
                        if let letter = pin.letter {
                            Text(letter).font(.caption.bold()).foregroundStyle(Palette.iconInk(colorIndex, hex: customColorHex)).padding(6)
                                .background(Palette.accent(colorIndex, hex: customColorHex), in: Circle())
                        } else {
                            Image(systemName: "mappin.circle.fill").font(.largeTitle)
                                .symbolRenderingMode(.palette).foregroundStyle(Palette.iconInk(colorIndex, hex: customColorHex), Palette.accent(colorIndex, hex: customColorHex))
                        }
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
                if let point = proxy.convert(event.location, from: .local) { tapped(Coordinate(latitude: point.latitude, longitude: point.longitude)) }
            })
            .accessibilityIdentifier("place-pin-map")
        }
        .onAppear { frame(restore: true) }
        .onChange(of: focusRequest) { _, _ in frame(restore: false) }
        .onChange(of: presentation.pins.first?.coordinate) { old, new in
            // Drawing corners must never reset the camera while drawing.
            if presentation.pins.first?.letter == nil, let new, old.map({ $0.distance(to: new) > 500 }) ?? true { frame(restore: false) }
        }
    }
    private func frame(restore: Bool) {
        if let region = restore ? (viewport ?? presentation.fittingViewport) : presentation.fittingViewport {
            camera = .region(MKCoordinateRegion(center: region.center.mapCoordinate,
                span: MKCoordinateSpan(latitudeDelta: region.latitudeSpan, longitudeDelta: region.longitudeSpan)))
        }
    }
}

struct PlaceAreaOverlay: MapContent {
    let areas: [PlaceArea]
    var colorIndex = 0
    var customColorHex: String?
    var body: some MapContent {
        ForEach(areas.indices, id: \.self) { areaIndex in
            ForEach(areas[areaIndex].polygons.indices, id: \.self) { index in
                MapPolygon(areas[areaIndex].polygons[index].mapPolygon)
                    .foregroundStyle(Palette.accent(colorIndex, hex: customColorHex).opacity(0.18))
                    .stroke(Palette.accent(colorIndex, hex: customColorHex), lineWidth: 2)
            }
        }
    }
}

private extension Coordinate {
    var mapCoordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
private extension PlaceArea.Polygon {
    var mapPolygon: MKPolygon {
        let interior = holes.map { points in MKPolygon(coordinates: points.map(\.mapCoordinate), count: points.count) }
        return MKPolygon(coordinates: outer.map(\.mapCoordinate), count: outer.count, interiorPolygons: interior)
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
