import Foundation
import CoreLocation

struct SavedSpot: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

@MainActor
final class SavedSpots: ObservableObject {
    @Published private(set) var spots: [SavedSpot] = []

    private let key = "savedSpots"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([SavedSpot].self, from: data) {
            spots = decoded
        }
    }

    func add(name: String, coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        spots.append(SavedSpot(name: trimmed.isEmpty ? "Saved spot" : trimmed,
                               latitude: coordinate.latitude,
                               longitude: coordinate.longitude))
        save()
    }

    func remove(at offsets: IndexSet) {
        spots.remove(atOffsets: offsets)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(spots) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
