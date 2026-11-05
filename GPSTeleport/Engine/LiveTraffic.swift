import CoreLocation
import Foundation
import MapKit

/// A driving route with the speed of current traffic on each stretch, from Mapbox.
/// Mapbox's terms don't allow storing these results, so they're only kept in memory.
struct TrafficRoute {
    let coordinates: [CLLocationCoordinate2D]
    /// Meters per second between each pair of coordinates. Nil where Mapbox has no speed.
    let speeds: [Double?]
    let distance: CLLocationDistance
    let expectedTravelTime: TimeInterval
}

/// A route ready to drive, from Mapbox with live traffic or from Apple Maps without it.
struct PlannedRoute {
    let polyline: MKPolyline
    let distance: CLLocationDistance
    let expectedTravelTime: TimeInterval
    let trafficSpeeds: [Double?]?

    init(_ route: MKRoute) {
        polyline = route.polyline
        distance = route.distance
        expectedTravelTime = route.expectedTravelTime
        trafficSpeeds = nil
    }

    init(_ route: TrafficRoute) {
        polyline = MKPolyline(coordinates: route.coordinates, count: route.coordinates.count)
        distance = route.distance
        expectedTravelTime = route.expectedTravelTime
        trafficSpeeds = route.speeds
    }
}

enum LiveTraffic {
    static var hasToken: Bool { MapboxToken.load() != nil }

    /// Throws errors written for the user. They never contain the token.
    static func route(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) async throws -> TrafficRoute {
        guard let token = MapboxToken.load() else {
            throw DeviceError(message: "No Mapbox token yet. Add one in Setup.")
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.mapbox.com"
        components.path = "/directions/v5/mapbox/driving-traffic/\(start.longitude),\(start.latitude);\(end.longitude),\(end.latitude)"
        components.queryItems = [
            URLQueryItem(name: "annotations", value: "speed"),
            URLQueryItem(name: "overview", value: "full"),
            URLQueryItem(name: "geometries", value: "geojson"),
            URLQueryItem(name: "access_token", value: token),
        ]
        guard let url = components.url else {
            throw DeviceError(message: "Couldn't make the traffic request.")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            throw DeviceError(message: "Couldn't reach Mapbox for live traffic.")
        }

        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: break
        case 401, 403: throw DeviceError(message: "Mapbox didn't accept your token. Check it in Setup.")
        case 429: throw DeviceError(message: "Mapbox says too many requests. Try again in a minute.")
        default: throw DeviceError(message: "Mapbox couldn't find a route with live traffic.")
        }

        guard let found = try? JSONDecoder().decode(Response.self, from: data).routes.first else {
            throw DeviceError(message: "Mapbox couldn't find a route with live traffic.")
        }

        let coordinates = found.geometry.coordinates.compactMap { pair -> CLLocationCoordinate2D? in
            guard pair.count >= 2 else { return nil }
            return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
        }
        let speeds = found.legs.flatMap { $0.annotation?.speed ?? [] }
        // Each speed belongs to one stretch, so a different count means they can't be matched up.
        guard coordinates.count >= 2, speeds.count == coordinates.count - 1 else {
            throw DeviceError(message: "Mapbox had no traffic speeds for this route.")
        }

        return TrafficRoute(coordinates: coordinates, speeds: speeds,
                            distance: found.distance, expectedTravelTime: found.duration)
    }

    private struct Response: Decodable {
        let routes: [Route]

        struct Route: Decodable {
            let geometry: Geometry
            let distance: Double
            let duration: Double
            let legs: [Leg]
        }
        struct Geometry: Decodable {
            let coordinates: [[Double]]
        }
        struct Leg: Decodable {
            let annotation: Annotation?
        }
        struct Annotation: Decodable {
            let speed: [Double?]?
        }
    }
}
