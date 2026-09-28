import SwiftUI
import MapKit
import RaceStudioCore

/// Real map imagery underneath the racing line on the track map.
///
/// Google publishes no native Maps SDK for macOS — only iOS and Android — so the
/// native framework is MapKit, which needs no API key, no billing account, and no
/// third-party JavaScript. Satellite is the useful style for a circuit: it shows
/// the kerbs, apexes, and run-off the line actually relates to, which a road map of
/// a kart track does not have.
///
/// The map is told **exactly** which region the plot's ``GeoProjection`` covers
/// (``GeoRegion/covering(_:size:)``), rather than being given a zoom level to match
/// by eye — so the line sits on the ground it was recorded on, and stays there when
/// the pane is resized. MapKit projects in Mercator and the plot in
/// equirectangular-about-the-centroid; over a circuit a few hundred metres across
/// those differ by well under a pixel.
///
/// MapKit does **not** always show the region it is given: it will not zoom past
/// its limit (~0.54 m per point for satellite imagery), and silently shows a wider
/// region instead. Every region the view really shows is reported through
/// `onVisibleRegion`, so ``TrackMapView`` can draw the line at that scale rather
/// than at the scale it asked for — the gap between the two drew a 200 m circuit at
/// about twice the size of the ground under it.
///
/// MapKit's own gestures are disabled: zoom and pan are the track map's
/// `MapViewport`, applied to the projection, so the imagery follows the line.
struct TrackMapBackdropView: NSViewRepresentable {
    let region: GeoRegion
    let style: TrackMapBackdrop
    /// Told the region MapKit actually displays, whenever it changes.
    var onVisibleRegion: (GeoRegion) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MKMapView {
        let view = ReportingMapView()
        let coordinator = context.coordinator
        view.onLayout = { [weak view] in
            guard let view else { return }
            coordinator.laidOut(view)
        }
        // MapKit can accept a region and only widen it once it renders; the
        // delegate hears that change, layout and SwiftUI updates do not.
        view.delegate = coordinator
        view.isZoomEnabled = false
        view.isScrollEnabled = false
        view.isRotateEnabled = false
        view.isPitchEnabled = false
        view.showsCompass = false
        view.showsZoomControls = false
        // No point-of-interest clutter over a racing line.
        view.pointOfInterestFilter = .excludingAll
        apply(to: view, coordinator: coordinator)
        return view
    }

    func updateNSView(_ view: MKMapView, context: Context) {
        context.coordinator.onVisibleRegion = onVisibleRegion
        apply(to: view, coordinator: context.coordinator)
        context.coordinator.report(view.region, of: view)
    }

    /// Forwards the displayed region, once per change, off the SwiftUI update pass
    /// (reporting mutates the parent's state).
    final class Coordinator: NSObject, MKMapViewDelegate {
        var onVisibleRegion: (GeoRegion) -> Void = { _ in }
        /// The region last asked for, re-applied once the view has its real size.
        var target: MKCoordinateRegion?
        private var lastReported: MKCoordinateRegion?
        private var laidOutSize: CGSize = .zero

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            report(mapView.region, of: mapView)
        }

        /// SwiftUI creates the map with a zero frame and sizes it afterwards, so
        /// the first region is set on a view with no size (it reports a
        /// whole-world span). Re-apply it once the size is real — and only when
        /// the size changes, since `setRegion` itself triggers layout.
        func laidOut(_ view: MKMapView) {
            if view.bounds.size != laidOutSize {
                laidOutSize = view.bounds.size
                // Deferred to the next runloop turn rather than re-entering
                // MapKit from inside its own layout pass.
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view, let target = self.target,
                          view.bounds.width > 0, view.bounds.height > 0 else { return }
                    view.setRegion(target, animated: false)
                    self.report(view.region, of: view)
                }
                return
            }
            report(view.region, of: view)
        }

        func report(_ region: MKCoordinateRegion, of view: MKMapView) {
            // A view not laid out yet reports a whole-world region; ignore it.
            guard view.bounds.width > 0, view.bounds.height > 0 else { return }
            if let lastReported, lastReported.approximatelyEquals(region) { return }
            lastReported = region
            let shown = GeoRegion(center: GPSCoord(latitude: region.center.latitude,
                                                   longitude: region.center.longitude),
                                  latitudeDelta: region.span.latitudeDelta,
                                  longitudeDelta: region.span.longitudeDelta)
            let callback = onVisibleRegion
            DispatchQueue.main.async { callback(shown) }
        }
    }

    /// An `MKMapView` that says when it has been laid out — the first moment its
    /// region reflects its real size.
    final class ReportingMapView: MKMapView {
        var onLayout: (() -> Void)?

        override func layout() {
            super.layout()
            onLayout?()
        }
    }

    private func apply(to view: MKMapView, coordinator: Coordinator) {
        view.mapType = style.mapType
        let target = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: region.center.latitude,
                                           longitude: region.center.longitude),
            span: MKCoordinateSpan(latitudeDelta: region.latitudeDelta,
                                   longitudeDelta: region.longitudeDelta))
        coordinator.target = target
        // Only re-set when it actually moved: assigning the region restarts MapKit's
        // tile fetch, and this runs on every cursor move.
        if !view.region.approximatelyEquals(target) {
            view.setRegion(target, animated: false)
        }
    }
}

private extension TrackMapBackdrop {
    /// The MapKit style this backdrop draws. ``TrackMapBackdrop/none`` never reaches
    /// here — the view is omitted entirely rather than drawn blank.
    var mapType: MKMapType {
        switch self {
        case .satellite: return .satellite
        case .hybrid: return .hybrid
        case .standard, .none: return .standard
        }
    }
}

private extension MKCoordinateRegion {
    /// Whether this region is close enough to `other` to leave the map alone.
    /// The tolerance is a fraction of the span, so it scales with the zoom.
    func approximatelyEquals(_ other: MKCoordinateRegion) -> Bool {
        let tolerance = max(other.span.latitudeDelta, other.span.longitudeDelta) * 1e-4
        return abs(center.latitude - other.center.latitude) < tolerance
            && abs(center.longitude - other.center.longitude) < tolerance
            && abs(span.latitudeDelta - other.span.latitudeDelta) < tolerance
            && abs(span.longitudeDelta - other.span.longitudeDelta) < tolerance
    }
}
