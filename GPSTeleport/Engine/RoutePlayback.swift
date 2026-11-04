import CoreLocation
import MapKit

/// Tracks a position moving along a route's points at whatever distance it's told to advance.
struct RoutePlayback {
    private let points: [CLLocationCoordinate2D]
    /// Distance from the start of the route to each point.
    private let distances: [CLLocationDistance]
    private var segment = 0

    private(set) var traveled: CLLocationDistance = 0
    let totalDistance: CLLocationDistance

    /// Returns nil unless the points cover some distance.
    init?(points: [CLLocationCoordinate2D]) {
        guard let first = points.first else { return nil }

        var kept = [first]
        var distances: [CLLocationDistance] = [0]
        var previous = CLLocation(latitude: first.latitude, longitude: first.longitude)
        for point in points.dropFirst() {
            let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
            let step = location.distance(from: previous)
            guard step > 0 else { continue }
            kept.append(point)
            distances.append(distances[distances.count - 1] + step)
            previous = location
        }

        guard let total = distances.last, total > 0 else { return nil }
        self.points = kept
        self.distances = distances
        self.totalDistance = total
    }

    var isFinished: Bool { traveled >= totalDistance }
    var remaining: CLLocationDistance { max(totalDistance - traveled, 0) }
    var fractionComplete: Double { min(traveled / totalDistance, 1) }

    mutating func advance(by meters: CLLocationDistance) {
        traveled = min(traveled + max(meters, 0), totalDistance)
        while segment < points.count - 2, distances[segment + 1] <= traveled {
            segment += 1
        }
    }

    var coordinate: CLLocationCoordinate2D {
        let start = points[segment]
        let end = points[segment + 1]
        let length = distances[segment + 1] - distances[segment]
        let fraction = min(max((traveled - distances[segment]) / length, 0), 1)
        return CLLocationCoordinate2D(
            latitude: start.latitude + (end.latitude - start.latitude) * fraction,
            longitude: start.longitude + (end.longitude - start.longitude) * fraction
        )
    }
}

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var result = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&result, range: NSRange(location: 0, length: pointCount))
        return result
    }
}
