import Foundation

@Observable
final class LightController {
    private let homeKitService: HomeKitService

    init(homeKitService: HomeKitService) {
        self.homeKitService = homeKitService
    }

    func applyLightState(
        brightness: Int,
        hue: Double,
        saturation: Double,
        powerOn: Bool,
        to accessoryID: UUID
    ) async throws {
        try await homeKitService.setPowerState(powerOn, for: accessoryID)
        try await homeKitService.setBrightness(brightness, for: accessoryID)

        // Color characteristics may not be available on white-only bulbs
        do {
            try await homeKitService.setHue(hue, for: accessoryID)
            try await homeKitService.setSaturation(saturation, for: accessoryID)
        } catch HomeKitServiceError.characteristicNotFound {
            // Light doesn't support color -- skip gracefully
        }
    }

    func applyToMultipleLights(
        brightness: Int,
        hue: Double,
        saturation: Double,
        powerOn: Bool,
        identifiers: [UUID]
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in identifiers {
                group.addTask {
                    try await self.applyLightState(
                        brightness: brightness,
                        hue: hue,
                        saturation: saturation,
                        powerOn: powerOn,
                        to: id
                    )
                }
            }
            try await group.waitForAll()
        }
    }
}
