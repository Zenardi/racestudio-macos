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
/// Interaction is disabled: the region is owned by the projection, so letting the
/// user pan or zoom the map would slide the imagery out from under the line.
struct TrackMapBackdropView: NSViewRepresentable {
    let region: GeoRegion
    let style: TrackMapBackdrop

    func makeNSView(context: Context) -> MKMapView {
        let view = MKMapView()
        view.isZoomEnabled = false
        view.isScrollEnabled = false
        view.isRotateEnabled = false
        view.isPitchEnabled = false
        view.showsCompass = false
        view.showsZoomControls = false
        // No point-of-interest clutter over a racing line.
        view.pointOfInterestFilter = .excludingAll
        apply(to: view)
        return view
    }

    func updateNSView(_ view: MKMapView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: MKMapView) {
        view.mapType = style.mapType
        let target = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: region.center.latitude,
                                           longitude: region.center.longitude),
            span: MKCoordinateSpan(latitudeDelta: region.latitudeDelta,
                                   longitudeDelta: region.longitudeDelta))
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
