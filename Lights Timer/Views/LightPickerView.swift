import SwiftUI
import HomeKit

struct LightPickerView: View {
    @Environment(HomeKitService.self) private var homeKit
    @Binding var selectedIdentifiers: [String]
    @Binding var selectedNames: [String]

    var body: some View {
        List {
            if homeKit.availableLights.isEmpty {
                ContentUnavailableView {
                    Label("No Lights Found", systemImage: "lightbulb.slash")
                } description: {
                    Text("Make sure your HomeKit lights are set up in the Home app and that you've granted permission to access HomeKit.")
                }
            } else if homeKit.homes.count > 1 {
                ForEach(homeKit.homes, id: \.uniqueIdentifier) { home in
                    let homeLights = lightsInHome(home)
                    if !homeLights.isEmpty {
                        Section(home.name) {
                            ForEach(homeLights, id: \.uniqueIdentifier) { accessory in
                                lightRow(accessory)
                            }
                        }
                    }
                }
            } else {
                Section {
                    ForEach(homeKit.availableLights, id: \.uniqueIdentifier) { accessory in
                        lightRow(accessory)
                    }
                }
            }
        }
        .navigationTitle("Select Lights")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func lightRow(_ accessory: HMAccessory) -> some View {
        let id = accessory.uniqueIdentifier.uuidString
        let isSelected = selectedIdentifiers.contains(id)

        return Button {
            if isSelected {
                if let index = selectedIdentifiers.firstIndex(of: id) {
                    selectedIdentifiers.remove(at: index)
                    selectedNames.remove(at: index)
                }
            } else {
                selectedIdentifiers.append(id)
                selectedNames.append(accessory.name)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(accessory.name)
                        .foregroundStyle(.primary)
                    if let room = accessory.room {
                        Text(room.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.orange)
                        .imageScale(.large)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                        .imageScale(.large)
                }
            }
        }
        .tint(.primary)
    }

    private func lightsInHome(_ home: HMHome) -> [HMAccessory] {
        homeKit.availableLights.filter { light in
            home.accessories.contains(where: { $0.uniqueIdentifier == light.uniqueIdentifier })
        }
    }
}
