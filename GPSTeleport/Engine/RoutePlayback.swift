import CoreLocation
import MapKit

/// Tracks a position moving along a route's points at whatever distance it's told to advance.
struct RoutePlayback {
    /// The slowest stretch speed used, so a reported 0 can't stop a drive for good.
    private static let minimumSpeed = 1.0

    private let points: [CLLocationCoordinate2D]
    /// Distance from the start of the route to each point.
    private let distances: [CLLocationDistance]
    /// Traffic speed for the stretch after each point, in meters per second, if known.
    private let speeds: [Double?]?
    private var segment = 0

    private(set) var traveled: CLLocationDistance = 0
    let totalDistance: CLLocationDistance
    /// Distance already driven before this route took over, when live traffic replaces a route.
    let earlierDistance: CLLocationDistance

    /// Returns nil unless the points cover some distance.
    init?(points: [CLLocationCoordinate2D], speeds: [Double?]? = nil, earlierDistance: CLLocationDistance = 0) {
        guard let first = points.first else { return nil }
        let usableSpeeds = speeds?.count == points.count - 1 ? speeds : nil

        var kept = [first]
        var distances: [CLLocationDistance] = [0]
        var keptSpeeds: [Double?] = []
        var previous = CLLocation(latitude: first.latitude, longitude: first.longitude)
        for (index, point) in points.enumerated().dropFirst() {
            let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
            let step = location.distance(from: previous)
            guard step > 0 else { continue }
            kept.append(point)
            distances.append(distances[distances.count - 1] + step)
            keptSpeeds.append(usableSpeeds?[index - 1] ?? nil)
            previous = location
        }

        guard let total = distances.last, total > 0 else { return nil }
        self.points = kept
        self.distances = distances
        self.speeds = usableSpeeds == nil ? nil : keptSpeeds
        self.totalDistance = total
        self.earlierDistance = earlierDistance
    }

    var isFinished: Bool { traveled >= totalDistance }
    var remaining: CLLocationDistance { max(totalDistance - traveled, 0) }
    var hasTrafficSpeeds: Bool { speeds != nil }
    /// All the distance covered on this trip, including on any route this one replaced.
    var tripDistance: CLLocationDistance { earlierDistance + traveled }
    var fractionComplete: Double { min(tripDistance / (earlierDistance + totalDistance), 1) }
    var destination: CLLocationCoordinate2D { points[points.count - 1] }

    /// The traffic speed on the current stretch, if known.
    var currentTrafficSpeed: Double? {
        speeds?[segment].map { max($0, Self.minimumSpeed) }
    }

    /// Time left at traffic speeds, using `fallback` on stretches with no known speed.
    func secondsRemaining(fallback: Double) -> TimeInterval {
        guard let speeds else { return remaining / fallback }
        var seconds: TimeInterval = 0
        for index in segment..<speeds.count {
            let speed = speeds[index].map { max($0, Self.minimumSpeed) } ?? fallback
            let start = max(distances[index], traveled)
            seconds += max(distances[index + 1] - start, 0) / speed
        }
        return seconds
    }

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
