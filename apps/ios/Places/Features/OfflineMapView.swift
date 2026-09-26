import SwiftUI
@preconcurrency import MapLibre
import PlacesCore

// The renderer has no network permission. Only the explicit download manager
// can fetch archives; even a mistakenly added remote style resource is blocked.
final class OfflineMapNetworkBlocker: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

@MainActor private enum OfflineMapNetwork {
    static let configure: Void = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineMapNetworkBlocker.self]
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        MLNNetworkConfiguration.sharedManager.sessionConfiguration = configuration
    }()
}

struct OfflineMapView: View {
    @Environment(AppModel.self) private var model
    let presentation: MapPresentation
    @Binding var viewport: MapViewport?
    var pinChanged: ((Coordinate) -> Void)?
    @State private var selectedPlace: Place?
    @State private var showSettings = false
    @State private var suggestedPack: MapPack?
    @State private var offered = false
    @State private var settleTask: Task<Void, Never>?
    @State private var mapIssue: String?
    var body: some View {
        OfflineMapSurface(presentation: presentation, installed: model.mapDownloads.installed, viewport: $viewport,
            pinChanged: pinChanged,
            selected: { pin in selectedPlace = model.places.first { $0.id == pin.placeID } },
            settled: suggestCountry, failed: { mapIssue = "The downloaded map could not be displayed." })
            .accessibilityIdentifier(pinChanged == nil ? "on-device-map" : "place-pin-map")
            .overlay(alignment: .top) {
                if let message = banner {
                    Button { showSettings = true } label: {
                        Label(message, systemImage: "arrow.down.circle").font(.subheadline)
                            .padding(12).frame(maxWidth: .infinity).background(Palette.paper)
                    }.accessibilityIdentifier("map-download-banner")
                }
            }
            .overlay(alignment: .bottom) {
                if let pack = suggestedPack {
                    HStack(spacing: Layout.compact) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("More detail for \(pack.name)").font(.subheadline.weight(.semibold))
                            MapPackDownloadButton(pack: pack, title: "Download · \(pack.sizeLabel)")
                        }
                        Spacer(minLength: 0)
                        Button("Not now", systemImage: "xmark") {
                            model.mapDownloads.dismissSuggestion(pack.id); suggestedPack = nil
                        }.labelStyle(.iconOnly).frame(width: Layout.touchTarget, height: Layout.touchTarget)
                    }.padding(12).background(Palette.paper, in: RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 12).padding(.bottom, 40)
                }
            }
            .onChange(of: model.mapDownloads.pending) { _, pending in
                if let pack = suggestedPack, pending.contains(pack.id) { suggestedPack = nil }
            }
            .onDisappear { settleTask?.cancel() }
            .sheet(isPresented: $showSettings) {
                NavigationStack { MapsSettings().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } } }
            }
            .sheet(item: $selectedPlace) { place in NavigationStack { PlaceDetail(placeID: place.id) } }
    }
    private var banner: String? {
        if let mapIssue { return mapIssue + " Manage maps" }
        if let issue = model.mapDownloads.issue { return issue + " · Maps settings" }
        if !model.mapDownloads.pending.isEmpty { return "Maps are downloading · View progress" }
        if model.mapDownloads.installed[.world] == nil { return "Download the World map · Maps settings" }
        if model.mapDownloads.transfers.values.contains(where: { $0.phase == .paused || $0.phase == .failed }) { return "Map download paused · Maps settings" }
        return nil
    }
    private func suggestCountry(_ center: Coordinate, _ zoom: Double) {
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, pinChanged == nil, model.mapDownloads.installed[.world] != nil,
                  let id = OfflineMapCoverage.country(at: center),
                  MapDownloadPolicy.canSuggest(id: id, zoom: zoom, installed: Set(model.mapDownloads.installed.keys),
                    pending: model.mapDownloads.pending, dismissedAt: model.mapDownloads.dismissedAt(id), now: Date(), offeredThisSession: offered),
                  let pack = model.mapDownloads.pack(id) else { return }
            offered = true; suggestedPack = pack
        }
    }
}

private struct OfflineMapSurface: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let presentation: MapPresentation
    let installed: [MapPack.ID: URL]
    @Binding var viewport: MapViewport?
    let pinChanged: ((Coordinate) -> Void)?
    let selected: (MapPin) -> Void
    let settled: (Coordinate, Double) -> Void
    let failed: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> MLNMapView {
        _ = OfflineMapNetwork.configure
        let json = (try? OfflineMapStyle.make(installed: installed, dark: colorScheme == .dark)) ?? OfflineMapStyle.empty
        let map = MLNMapView(frame: .zero, styleJSON: json)
        context.coordinator.styleSignature = signature
        map.delegate = context.coordinator
        map.showsUserLocation = false; map.maximumZoomLevel = 17
        map.logoView.isHidden = true
        map.isPitchEnabled = false; map.isRotateEnabled = false
        if pinChanged != nil {
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
            for gesture in map.gestureRecognizers ?? [] where (gesture as? UITapGestureRecognizer)?.numberOfTapsRequired == 2 { tap.require(toFail: gesture) }
            map.addGestureRecognizer(tap)
        }
        return map
    }
    private var signature: String { installed.keys.sorted { $0.rawValue < $1.rawValue }.map { installed[$0]!.path }.joined() + (colorScheme == .dark ? "dark" : "light") }
    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.styleSignature != signature {
            context.coordinator.styleSignature = signature
            map.styleJSON = (try? OfflineMapStyle.make(installed: installed, dark: colorScheme == .dark)) ?? OfflineMapStyle.empty
            context.coordinator.rendered = nil
        }
        context.coordinator.render(map)
    }
    static func dismantleUIView(_ view: MLNMapView, coordinator: Coordinator) { view.delegate = nil }

    @MainActor final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
        var parent: OfflineMapSurface
        var styleSignature = ""
        var rendered: MapPresentation?
        var framed = false
        var routeLayerIDs: [String] = []
        var annotations: [MapAnnotation] = []
        init(_ parent: OfflineMapSurface) { self.parent = parent }
        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            rendered = nil; routeLayerIDs = []; render(mapView)
            // Installing a pack reloads the style without moving the camera.
            // Re-evaluate country detail after World finishes downloading too.
            self.mapView(mapView, regionDidChangeAnimated: false)
        }
        func mapViewDidFinishLoadingMap(_ mapView: MLNMapView) { frame(mapView) }
        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) { parent.failed() }
        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            guard framed else { return }
            let bounds = mapView.visibleCoordinateBounds
            let center = Coordinate(latitude: mapView.centerCoordinate.latitude, longitude: mapView.centerCoordinate.longitude)
            parent.viewport = MapViewport(center: center, latitudeSpan: max(0.0001, bounds.ne.latitude - bounds.sw.latitude),
                longitudeSpan: max(0.0001, bounds.ne.longitude - bounds.sw.longitude))
            parent.settled(center, mapView.zoomLevel)
        }
        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let map = gesture.view as? MLNMapView else { return }
            let point = map.convert(gesture.location(in: map), toCoordinateFrom: map)
            let coordinate = Coordinate(latitude: point.latitude, longitude: point.longitude)
            if coordinate.isValid { parent.pinChanged?(coordinate) }
        }
        func render(_ map: MLNMapView) {
            guard let style = map.style, rendered != parent.presentation else { frame(map); return }
            if let rendered, rendered.coordinates != parent.presentation.coordinates, parent.pinChanged == nil { framed = false; parent.viewport = nil }
            if parent.pinChanged != nil, let point = parent.presentation.pins.first?.coordinate,
               (rendered?.pins.first?.coordinate).map({ $0.distance(to: point) > 500 }) ?? true {
                framed = false; parent.viewport = nil
            }
            rendered = parent.presentation
            for id in routeLayerIDs {
                if let layer = style.layer(withIdentifier: id) { style.removeLayer(layer) }
                if let source = style.source(withIdentifier: id) { style.removeSource(source) }
            }
            routeLayerIDs = []
            for (index, path) in parent.presentation.paths.enumerated() where path.coordinates.count > 1 {
                let id = "history-route-\(index)"
                var points = path.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                let shape = MLNPolyline(coordinates: &points, count: UInt(points.count))
                let source = MLNShapeSource(identifier: id, shape: shape, options: nil)
                let layer = MLNLineStyleLayer(identifier: id, source: source)
                layer.lineColor = NSExpression(forConstantValue: UIColor(path.dashed ? Palette.muted : Palette.green))
                layer.lineWidth = NSExpression(forConstantValue: path.dashed ? 3 : 4)
                if path.dashed { layer.lineDashPattern = NSExpression(forConstantValue: [2, 2]) }
                style.addSource(source); style.addLayer(layer); routeLayerIDs.append(id)
            }
            if let radius = parent.presentation.radius, let pin = parent.presentation.pins.first {
                let center = pin.coordinate
                var points = (0...64).map { step -> CLLocationCoordinate2D in
                    let angle = Double(step) * .pi / 32
                    return CLLocationCoordinate2D(latitude: center.latitude + sin(angle) * radius / 111_320,
                        longitude: center.longitude + cos(angle) * radius / (111_320 * max(0.01, cos(center.latitude * .pi / 180))))
                }
                let id = "place-radius"
                let source = MLNShapeSource(identifier: id, shape: MLNPolygon(coordinates: &points, count: UInt(points.count)), options: nil)
                let layer = MLNFillStyleLayer(identifier: id, source: source)
                layer.fillColor = NSExpression(forConstantValue: UIColor(Palette.accent(pin.colorIndex)))
                layer.fillOpacity = NSExpression(forConstantValue: 0.2)
                style.addSource(source); style.addLayer(layer); routeLayerIDs.append(id)
            }
            if !annotations.isEmpty { map.removeAnnotations(annotations) }
            annotations = parent.presentation.pins.map(MapAnnotation.init)
            map.addAnnotations(annotations)
            frame(map)
        }
        func frame(_ map: MLNMapView) {
            guard !framed, map.bounds.width > 0, map.bounds.height > 0 else { return }
            framed = true
            if let viewport = parent.viewport {
                let center = viewport.center
                map.setVisibleCoordinateBounds(MLNCoordinateBounds(
                    sw: CLLocationCoordinate2D(latitude: max(-85, center.latitude - viewport.latitudeSpan / 2), longitude: center.longitude - viewport.longitudeSpan / 2),
                    ne: CLLocationCoordinate2D(latitude: min(85, center.latitude + viewport.latitudeSpan / 2), longitude: center.longitude + viewport.longitudeSpan / 2)), animated: false)
            } else {
                let points = parent.presentation.coordinates
                if Set(points).count == 1, let point = points.first {
                    map.setCenter(CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude), zoomLevel: 14, animated: false)
                } else if let first = points.first {
                    let south = points.map(\.latitude).min() ?? first.latitude, north = points.map(\.latitude).max() ?? first.latitude
                    let west = points.map(\.longitude).min() ?? first.longitude, east = points.map(\.longitude).max() ?? first.longitude
                    map.setVisibleCoordinateBounds(MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: south, longitude: west), ne: CLLocationCoordinate2D(latitude: north, longitude: east)), edgePadding: UIEdgeInsets(top: 70, left: 45, bottom: 70, right: 45), animated: false, completionHandler: nil)
                } else { map.setCenter(CLLocationCoordinate2D(latitude: 20, longitude: 0), zoomLevel: 1, animated: false) }
            }
        }
        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            guard let annotation = annotation as? MapAnnotation else { return nil }
            let pin = annotation.pin
            let view = MLNAnnotationView(annotation: annotation, reuseIdentifier: nil)
            view.frame = CGRect(x: 0, y: 0, width: 140, height: 70)
            view.isAccessibilityElement = true; view.accessibilityLabel = pin.name
            let badge = UIView(frame: CGRect(x: 50, y: 0, width: 40, height: 40))
            badge.backgroundColor = UIColor(Palette.accent(pin.colorIndex)); badge.layer.cornerRadius = 14
            if let letter = pin.letter {
                let text = UILabel(frame: badge.bounds); text.text = letter; text.textAlignment = .center
                text.font = .boldSystemFont(ofSize: 20); text.textColor = .white; badge.addSubview(text)
            } else {
                let image = UIImageView(image: UIImage(systemName: pin.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 23, weight: .semibold)))
                image.tintColor = .white; image.contentMode = .scaleAspectFit; image.frame = badge.bounds.insetBy(dx: 7, dy: 7); badge.addSubview(image)
            }
            view.addSubview(badge)
            let label = UILabel(frame: CGRect(x: 0, y: 44, width: 140, height: 26))
            label.text = pin.name; label.textAlignment = .center; label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = UIColor(Palette.ink); label.backgroundColor = UIColor(Palette.paper).withAlphaComponent(0.9)
            label.layer.cornerRadius = 6; label.clipsToBounds = true; label.adjustsFontSizeToFitWidth = true; label.minimumScaleFactor = 0.8
            view.addSubview(label); return view
        }
        func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            if let annotation = annotation as? MapAnnotation { parent.selected(annotation.pin) }
            mapView.deselectAnnotation(annotation, animated: false)
        }
    }
}

private final class MapAnnotation: MLNPointAnnotation {
    let pin: MapPin
    init(_ pin: MapPin) {
        self.pin = pin; super.init()
        coordinate = CLLocationCoordinate2D(latitude: pin.coordinate.latitude, longitude: pin.coordinate.longitude)
        title = pin.name
    }
    required init?(coder: NSCoder) { nil }
}
