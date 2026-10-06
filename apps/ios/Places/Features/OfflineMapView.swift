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
    var focusRequest: UUID?
    var chromeInsets = EdgeInsets()
    var pinChanged: ((Coordinate) -> Void)?
    var rawPointSelected: ((RawMapPoint) -> Void)?
    @State private var selectedPlace: Place?
    @State private var showSettings = false
    @State private var suggestedPack: MapPack?
    @State private var offered: Set<MapPack.ID> = []
    @State private var settleTask: Task<Void, Never>?
    @State private var mapIssue: String?
    var body: some View {
        OfflineMapSurface(presentation: presentation, installed: model.mapDownloads.installed, viewport: $viewport, focusRequest: focusRequest, chromeInsets: chromeInsets,
            pinChanged: pinChanged,
            selected: { pin in selectedPlace = model.places.first { $0.id == pin.placeID } },
            settled: suggestCountry, failed: { mapIssue = "The downloaded map could not be displayed." },
            rawPointSelected: rawPointSelected)
            .accessibilityIdentifier(pinChanged == nil ? "on-device-map" : "place-pin-map")
            .overlay(alignment: .top) {
                if let message = banner {
                    Button { showSettings = true } label: {
                        Label(message, systemImage: "arrow.down.circle").font(.subheadline)
                            .padding(12).frame(maxWidth: .infinity).background(Palette.paper)
                    }.accessibilityIdentifier("map-download-banner").padding(.top, chromeInsets.top)
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
                        .padding(.horizontal, 12).padding(.bottom, chromeInsets.bottom + 40)
                }
            }
            .onChange(of: model.mapDownloads.pending) { _, pending in
                if let pack = suggestedPack, pending.contains(pack.id) { suggestedPack = nil }
            }
            .onDisappear { settleTask?.cancel() }
            .sheet(isPresented: $showSettings) {
                NavigationStack { MapsSettings().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } } }
            }
            .sheet(item: $selectedPlace) { place in NavigationStack { PlaceDetail(placeID: place.id) }.environment(\.hasMainNavigation, false) }
    }
    private var banner: String? {
        if let mapIssue { return mapIssue + " Manage maps" }
        if let issue = model.mapDownloads.issue { return issue + " · Maps settings" }
        if !model.mapDownloads.pending.isEmpty { return "Maps are downloading · View progress" }
        if model.mapDownloads.installed[.world] == nil { return "Download the World map · Maps settings" }
        if model.mapDownloads.transfers.values.contains(where: { $0.phase == .paused || $0.phase == .failed }) { return "Map download paused · Maps settings" }
        return nil
    }
    private func suggestCountry(_ viewport: MapViewport, _ zoom: Double) {
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, pinChanged == nil, model.mapDownloads.installed[.world] != nil else { return }
            let candidates = OfflineMapCoverage.countries(in: viewport, available: Set(model.mapDownloads.packs.map(\.id)))
            if let current = suggestedPack, (!candidates.contains(current.id) || zoom < 8 || model.mapDownloads.installed[current.id] != nil) {
                suggestedPack = nil
            }
            guard suggestedPack == nil,
                  let id = candidates.first(where: {
                    MapDownloadPolicy.canSuggest(id: $0, zoom: zoom, installed: Set(model.mapDownloads.installed.keys),
                        pending: model.mapDownloads.pending, dismissedAt: model.mapDownloads.dismissedAt($0), now: Date(), offeredThisSession: offered)
                  }), let pack = model.mapDownloads.pack(id) else { return }
            offered.insert(id); suggestedPack = pack
        }
    }
}

struct OfflineMapSurface: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let presentation: MapPresentation
    let installed: [MapPack.ID: URL]
    @Binding var viewport: MapViewport?
    let focusRequest: UUID?
    let chromeInsets: EdgeInsets
    let pinChanged: ((Coordinate) -> Void)?
    let selected: (MapPin) -> Void
    let settled: (MapViewport, Double) -> Void
    let failed: () -> Void
    var rawPointSelected: ((RawMapPoint) -> Void)?
    var interactive = true
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> MLNMapView {
        _ = OfflineMapNetwork.configure
        let json = (try? OfflineMapStyle.make(installed: installed, dark: colorScheme == .dark)) ?? OfflineMapStyle.empty
        let map = OfflineMapCanvas(frame: .zero, styleJSON: json)
        map.didLayout = { [weak coordinator = context.coordinator] map in coordinator?.render(map) }
        context.coordinator.styleSignature = signature
        map.delegate = context.coordinator
        map.automaticallyAdjustsContentInset = false
        map.showsUserLocation = false; map.maximumZoomLevel = 17
        // Keep the viewport inside the drawable Mercator world, including when
        // zooming out or panning towards a pole on a tall screen.
        map.maximumScreenBounds = MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(latitude: -85.05112878, longitude: -180),
            ne: CLLocationCoordinate2D(latitude: 85.05112878, longitude: 180))
        map.logoView.isHidden = true
        map.isUserInteractionEnabled = interactive
        if !interactive { map.attributionButton.isHidden = true; map.compassView.isHidden = true }
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
        let attributionMargin = CGPoint(x: 12, y: 8 + max(0, chromeInsets.bottom - map.safeAreaInsets.bottom))
        if map.attributionButtonMargins != attributionMargin { map.attributionButtonMargins = attributionMargin }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            context.coordinator.framed = false
            context.coordinator.restoreViewport = false
        }
        if context.coordinator.styleSignature != signature {
            context.coordinator.styleSignature = signature
            map.styleJSON = (try? OfflineMapStyle.make(installed: installed, dark: colorScheme == .dark)) ?? OfflineMapStyle.empty
            context.coordinator.rendered = nil
        }
        context.coordinator.render(map)
    }
    static func dismantleUIView(_ view: MLNMapView, coordinator: Coordinator) {
        view.delegate = nil
        (view as? OfflineMapCanvas)?.didLayout = nil
    }

    @MainActor final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
        var parent: OfflineMapSurface
        var styleSignature = ""
        var rendered: MapPresentation?
        var framed = false
        var focusRequest: UUID?
        var restoreViewport = true
        var routeLayerIDs: [String] = []
        private var annotations: [MapAnnotation] = []
        private var rawAnnotations: [RawMapAnnotation] = []
        init(_ parent: OfflineMapSurface) { self.parent = parent; focusRequest = parent.focusRequest }
        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            rendered = nil; routeLayerIDs = []; render(mapView)
            // Installing a pack reloads the style without moving the camera.
            // Re-evaluate country detail after World finishes downloading too.
            self.mapView(mapView, regionDidChangeAnimated: false)
        }
        func mapViewDidFinishLoadingMap(_ mapView: MLNMapView) {
            render(mapView)
        }
        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) { parent.failed() }
        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            guard framed else { return }
            let bounds = mapView.visibleCoordinateBounds
            let center = Coordinate(latitude: (bounds.ne.latitude + bounds.sw.latitude) / 2,
                longitude: (bounds.ne.longitude + bounds.sw.longitude) / 2)
            let viewport = MapViewport(center: center, latitudeSpan: max(0.0001, bounds.ne.latitude - bounds.sw.latitude),
                longitudeSpan: max(0.0001, bounds.ne.longitude - bounds.sw.longitude))
            let request = parent.focusRequest, zoom = mapView.zoomLevel
            // Framing can synchronously call this delegate from updateUIView.
            // Deliver the settled camera after that SwiftUI update has finished.
            Task { @MainActor [weak self] in
                guard let self, self.parent.focusRequest == request else { return }
                self.parent.viewport = viewport
                self.parent.settled(viewport, zoom)
            }
        }
        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let map = gesture.view as? MLNMapView else { return }
            let point = map.convert(gesture.location(in: map), toCoordinateFrom: map)
            let coordinate = Coordinate(latitude: point.latitude, longitude: point.longitude)
            if coordinate.isValid { parent.pinChanged?(coordinate) }
        }
        func render(_ map: MLNMapView) {
            guard let style = map.style else { return }
            guard rendered != parent.presentation else { frame(map); return }
            if let rendered, rendered.coordinates != parent.presentation.coordinates, parent.pinChanged == nil { framed = false; restoreViewport = false }
            if parent.pinChanged != nil, parent.presentation.pins.first?.letter == nil, let point = parent.presentation.pins.first?.coordinate,
               (rendered?.pins.first?.coordinate).map({ $0.distance(to: point) > 500 }) ?? true {
                framed = false; restoreViewport = false
            }
            rendered = parent.presentation
            for id in routeLayerIDs {
                if let layer = style.layer(withIdentifier: id) { style.removeLayer(layer) }
            }
            for id in routeLayerIDs {
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
                style.addSource(source)
                if !parent.presentation.rawPoints.isEmpty, let labels = style.layers.first(where: { $0 is MLNSymbolStyleLayer }) {
                    // Keep the time-order line behind raw dot images and map labels.
                    style.insertLayer(layer, below: labels)
                } else { style.addLayer(layer) }
                routeLayerIDs.append(id)
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
                let color = UIColor(Palette.accent(pin.colorIndex, hex: pin.customColorHex))
                layer.fillColor = NSExpression(forConstantValue: color)
                layer.fillOpacity = NSExpression(forConstantValue: 0.2)
                let outline = MLNLineStyleLayer(identifier: id + "-outline", source: source)
                outline.lineColor = NSExpression(forConstantValue: color); outline.lineWidth = NSExpression(forConstantValue: 2)
                style.addSource(source); style.addLayer(layer); style.addLayer(outline)
                routeLayerIDs += [id, id + "-outline"]
            }
            for (index, polygon) in parent.presentation.areas.flatMap(\.polygons).enumerated() {
                let interior = polygon.holes.map { ring -> MLNPolygon in
                    var points = (ring + ring.prefix(1)).map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    return MLNPolygon(coordinates: &points, count: UInt(points.count))
                }
                var points = (polygon.outer + polygon.outer.prefix(1)).map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                let shape = MLNPolygon(coordinates: &points, count: UInt(points.count), interiorPolygons: interior)
                let id = "place-area-\(index)"
                let source = MLNShapeSource(identifier: id, shape: shape, options: nil)
                let color = UIColor(Palette.accent(parent.presentation.pins.first?.colorIndex ?? 0, hex: parent.presentation.pins.first?.customColorHex))
                let fill = MLNFillStyleLayer(identifier: id, source: source)
                fill.fillColor = NSExpression(forConstantValue: color); fill.fillOpacity = NSExpression(forConstantValue: 0.18)
                let line = MLNLineStyleLayer(identifier: id + "-outline", source: source)
                line.lineColor = NSExpression(forConstantValue: color); line.lineWidth = NSExpression(forConstantValue: 2)
                style.addSource(source); style.addLayer(fill); style.addLayer(line)
                routeLayerIDs += [id, id + "-outline"]
            }
            if !annotations.isEmpty { map.removeAnnotations(annotations) }
            annotations = parent.presentation.pins.map(MapAnnotation.init)
            map.addAnnotations(annotations)
            if !rawAnnotations.isEmpty { map.removeAnnotations(rawAnnotations) }
            rawAnnotations = parent.presentation.rawPoints.map(RawMapAnnotation.init)
            map.addAnnotations(rawAnnotations)
            frame(map)
        }
        func frame(_ map: MLNMapView) {
            // SwiftUI assigns bounds before MapLibre updates its internal viewport
            // in layoutSubviews. Fitting earlier uses the renderer's old zero size.
            guard !framed, map.style != nil, map.bounds.width > 0, map.bounds.height > 0,
                  (map as? OfflineMapCanvas)?.laidOutSize == map.bounds.size else { return }
            framed = true
            if restoreViewport, let viewport = parent.viewport {
                let center = viewport.center
                map.setVisibleCoordinateBounds(MLNCoordinateBounds(
                    sw: CLLocationCoordinate2D(latitude: max(-85, center.latitude - viewport.latitudeSpan / 2), longitude: center.longitude - viewport.longitudeSpan / 2),
                    ne: CLLocationCoordinate2D(latitude: min(85, center.latitude + viewport.latitudeSpan / 2), longitude: center.longitude + viewport.longitudeSpan / 2)), animated: false)
            } else {
                let points = parent.presentation.coordinates.filter(\.isValid)
                if Set(points).count == 1, let point = points.first {
                    map.setCenter(CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude), zoomLevel: 14, animated: false)
                } else if let region = parent.presentation.fittingViewport {
                    map.setVisibleCoordinateBounds(MLNCoordinateBounds(
                        sw: CLLocationCoordinate2D(latitude: max(-85, region.center.latitude - region.latitudeSpan / 2), longitude: region.center.longitude - region.longitudeSpan / 2),
                        ne: CLLocationCoordinate2D(latitude: min(85, region.center.latitude + region.latitudeSpan / 2), longitude: region.center.longitude + region.longitudeSpan / 2)),
                        edgePadding: UIEdgeInsets(top: 60 + parent.chromeInsets.top, left: 45 + parent.chromeInsets.leading,
                            bottom: 70 + parent.chromeInsets.bottom, right: 45 + parent.chromeInsets.trailing), animated: false, completionHandler: nil)
                } else { map.setCenter(CLLocationCoordinate2D(latitude: 20, longitude: 0), zoomLevel: 1, animated: false) }
            }
            // Padding is only for fitting places around the floating controls.
            // Keep the same visible camera with a full-screen logical viewport,
            // otherwise world bounds can leave a blank strip below the map.
            if map.cameraEdgeInsets != .zero {
                let center = map.convert(CGPoint(x: map.bounds.midX, y: map.bounds.midY), toCoordinateFrom: map)
                map.setCenter(center, zoomLevel: map.zoomLevel, animated: false)
            }
        }
        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            guard let annotation = annotation as? MapAnnotation else { return nil }
            let pin = annotation.pin
            let view = OfflineAnnotationView(annotation: annotation, reuseIdentifier: nil)
            if pin.isRecordedLocation {
                view.frame = CGRect(x: 0, y: 0, width: 14, height: 14)
                view.backgroundColor = UIColor(Palette.accent(pin.colorIndex)); view.layer.cornerRadius = 7
                view.layer.borderColor = UIColor.white.cgColor; view.layer.borderWidth = 2
                view.isAccessibilityElement = true; view.accessibilityLabel = pin.name
                return view
            }
            if pin.name.isEmpty, let letter = pin.letter {
                view.frame = CGRect(x: 0, y: 0, width: 26, height: 26)
                view.backgroundColor = UIColor(Palette.accent(pin.colorIndex, hex: pin.customColorHex)); view.layer.cornerRadius = 13
                let text = UILabel(frame: view.bounds); text.text = letter; text.textAlignment = .center
                text.font = .boldSystemFont(ofSize: 13); text.textColor = UIColor(Palette.iconInk(pin.colorIndex, hex: pin.customColorHex)); view.addSubview(text)
                view.isAccessibilityElement = true; view.accessibilityLabel = "Corner \(letter)"
                return view
            }
            view.frame = CGRect(x: 0, y: 0, width: 140, height: 70)
            view.isAccessibilityElement = true; view.accessibilityLabel = pin.name
            let badge = UIView(frame: CGRect(x: 50, y: 0, width: 40, height: 40))
            badge.backgroundColor = UIColor(Palette.accent(pin.colorIndex, hex: pin.customColorHex)); badge.layer.cornerRadius = 14
            if let letter = pin.letter {
                let text = UILabel(frame: badge.bounds); text.text = letter; text.textAlignment = .center
                text.font = .boldSystemFont(ofSize: 20); text.textColor = UIColor(Palette.iconInk(pin.colorIndex, hex: pin.customColorHex)); badge.addSubview(text)
            } else if let data = pin.photoJPEG, let photo = UIImage(data: data) {
                let image = UIImageView(image: photo)
                image.frame = badge.bounds; image.contentMode = .scaleAspectFill
                badge.clipsToBounds = true; badge.addSubview(image)
            } else {
                let image = UIImageView(image: UIImage(systemName: pin.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 23, weight: .semibold)))
                image.tintColor = UIColor(Palette.iconInk(pin.colorIndex, hex: pin.customColorHex)); image.contentMode = .scaleAspectFit; image.frame = badge.bounds.insetBy(dx: 7, dy: 7); badge.addSubview(image)
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
            if let annotation = annotation as? RawMapAnnotation { parent.rawPointSelected?(annotation.point) }
            mapView.deselectAnnotation(annotation, animated: false)
        }
        func mapView(_ mapView: MLNMapView, imageFor annotation: MLNAnnotation) -> MLNAnnotationImage? {
            guard let annotation = annotation as? RawMapAnnotation else { return nil }
            // Shared renderer images avoid one UIKit view per raw observation.
            let reuse = "raw-point-\(annotation.point.colorIndex)-\(parent.colorScheme)"
            if let image = mapView.dequeueReusableAnnotationImage(withIdentifier: reuse) { return image }
            let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
                UIColor.white.setFill(); context.cgContext.fillEllipse(in: CGRect(x: 2, y: 2, width: 16, height: 16))
                UIColor(Palette.accent(annotation.point.colorIndex)).setFill()
                context.cgContext.fillEllipse(in: CGRect(x: 4, y: 4, width: 12, height: 12))
            }
            return MLNAnnotationImage(image: image, reuseIdentifier: reuse)
        }
    }
}

private final class OfflineAnnotationView: MLNAnnotationView {
    // MapLibre returns the frame in map coordinates. Accessibility requires
    // screen coordinates, including the navigation bar above the map.
    override var accessibilityFrame: CGRect {
        get { UIAccessibility.convertToScreenCoordinates(bounds, in: self) }
        set { super.accessibilityFrame = newValue }
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

private final class RawMapAnnotation: MLNPointAnnotation {
    let point: RawMapPoint
    init(_ point: RawMapPoint) {
        self.point = point; super.init()
        coordinate = CLLocationCoordinate2D(latitude: point.coordinate.latitude, longitude: point.coordinate.longitude)
        title = point.accessibilityLabel
    }
    required init?(coder: NSCoder) { nil }
}

/// A map may finish loading before SwiftUI gives it its final layout.
private final class OfflineMapCanvas: MLNMapView {
    var didLayout: ((MLNMapView) -> Void)?
    private(set) var laidOutSize = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        laidOutSize = bounds.size
        didLayout?(self)
    }
}
