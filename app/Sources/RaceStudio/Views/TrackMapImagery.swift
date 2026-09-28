import AppKit
import MapKit
import RaceStudioCore

/// Fetches the still map imagery drawn under the track map's racing line.
///
/// Google publishes no native Maps SDK for macOS — only iOS and Android — so the
/// native framework is MapKit, which needs no API key, no billing account, and no
/// third-party JavaScript. Satellite is the useful style for a circuit: it shows
/// the kerbs, apexes, and run-off the line actually relates to.
///
/// Snapshots, not a live `MKMapView`: see `RaceStudioCore.MapImagery` for why. Two
/// are taken (`MapImagery.requests`) — a coarse one for context when zoomed out and
/// a fine one of the circuit — and each records where two coordinates landed in its
/// image, which is all ``TrackMapView`` needs to place it under any zoom and pan.
@MainActor
final class TrackMapImageryLoader: ObservableObject {
    /// A fetched layer: the image and its placement anchors.
    struct Layer {
        let image: NSImage
        let tile: MapImagery.Tile
    }

    /// The layers to draw, coarsest first. Kept while a new fetch is in flight —
    /// they are still the right ground, just framed for the previous laps.
    @Published private(set) var layers: [Layer] = []

    private var loadedKey: Key?
    private var snapshotters: [MKMapSnapshotter] = []

    private struct Key: Equatable {
        let region: GeoRegion
        let style: TrackMapBackdrop
    }

    /// Fetch imagery for a map framing `region` in `style`, unless that is what is
    /// already loaded. ``TrackMapBackdrop/none`` drops the imagery and fetches
    /// nothing, so the map makes no network requests unless asked.
    func load(framing region: GeoRegion?, style: TrackMapBackdrop) {
        guard style != .none, let region else {
            cancel()
            loadedKey = nil
            layers = []
            return
        }
        let key = Key(region: region, style: style)
        guard key != loadedKey else { return }
        cancel()
        loadedKey = key
        let requests = MapImagery.requests(framing: region)
        var fetched: [Int: Layer] = [:]
        var finished = 0
        for (order, request) in requests.enumerated() {
            let snapshotter = MKMapSnapshotter(options: options(for: request, style: style))
            snapshotters.append(snapshotter)
            snapshotter.start(with: .main) { [weak self] snapshot, _ in
                // A superseded fetch leaves the current imagery alone.
                guard let self, self.loadedKey == key else { return }
                finished += 1
                if let snapshot {
                    fetched[order] = Layer(image: snapshot.image, tile: Self.tile(of: snapshot, for: request))
                }
                // Swap in whatever arrived once every fetch is done — a failed
                // layer (offline, say) must not hold back the other — and keep the
                // old imagery if nothing did.
                if finished == requests.count, !fetched.isEmpty {
                    self.layers = requests.indices.compactMap { fetched[$0] }
                }
            }
        }
    }

    private func cancel() {
        snapshotters.forEach { $0.cancel() }
        snapshotters = []
    }

    private func options(for request: MapImagery.Request, style: TrackMapBackdrop) -> MKMapSnapshotter.Options {
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: request.region.center.latitude,
                                           longitude: request.region.center.longitude),
            span: MKCoordinateSpan(latitudeDelta: request.region.latitudeDelta,
                                   longitudeDelta: request.region.longitudeDelta))
        options.size = request.size
        options.mapType = style.mapType
        // No point-of-interest clutter over a racing line.
        options.pointOfInterestFilter = .excludingAll
        return options
    }

    /// Where the request's corners landed in the image. `point(for:)` counts `y`
    /// up from the bottom on macOS; the tile counts down from the top, like the view.
    private static func tile(of snapshot: MKMapSnapshotter.Snapshot,
                             for request: MapImagery.Request) -> MapImagery.Tile {
        let region = request.region
        let southWest = GPSCoord(latitude: region.center.latitude - region.latitudeDelta / 2,
                                 longitude: region.center.longitude - region.longitudeDelta / 2)
        let northEast = GPSCoord(latitude: region.center.latitude + region.latitudeDelta / 2,
                                 longitude: region.center.longitude + region.longitudeDelta / 2)
        let size = snapshot.image.size
        func topDown(_ coord: GPSCoord) -> CGPoint {
            let point = snapshot.point(for: CLLocationCoordinate2D(latitude: coord.latitude,
                                                                   longitude: coord.longitude))
            return CGPoint(x: point.x, y: size.height - point.y)
        }
        return MapImagery.Tile(size: size, southWest: southWest, southWestPoint: topDown(southWest),
                               northEast: northEast, northEastPoint: topDown(northEast))
    }
}

private extension TrackMapBackdrop {
    /// The MapKit style this backdrop draws. ``TrackMapBackdrop/none`` never reaches
    /// here — nothing is fetched for it.
    var mapType: MKMapType {
        switch self {
        case .satellite: return .satellite
        case .hybrid: return .hybrid
        case .standard, .none: return .standard
        }
    }
}
