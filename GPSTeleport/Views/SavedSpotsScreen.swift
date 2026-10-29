import SwiftUI

struct SavedSpotsScreen: View {
    @EnvironmentObject private var spots: SavedSpots
    @Environment(\.dismiss) private var dismiss
    let onSelect: (SavedSpot) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if spots.spots.isEmpty {
                    ContentUnavailableView("No saved spots",
                                           systemImage: "star",
                                           description: Text("Drop a pin on the map, then tap Save."))
                } else {
                    List {
                        ForEach(spots.spots) { spot in
                            Button { onSelect(spot) } label: {
                                VStack(alignment: .leading) {
                                    Text(spot.name).foregroundStyle(.primary)
                                    Text(String(format: "%.5f, %.5f", spot.latitude, spot.longitude))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete(perform: spots.remove)
                    }
                }
            }
            .navigationTitle("Saved spots")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
