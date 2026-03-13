import Foundation

struct MultiLightWriteSummary {
    let attempted: Int
    let succeeded: Int

    var failed: Int { attempted - succeeded }
    var hadAnySuccess: Bool { succeeded > 0 }
}

@Observable
final class LightController {
    private let homeKitService: HomeKitService
    private let logStore: PhoneLogStore

    init(homeKitService: HomeKitService, logStore: PhoneLogStore) {
        self.homeKitService = homeKitService
        self.logStore = logStore
    }

    func applyLightState(
        brightness: Int,
        hue: Double,
        saturation: Double,
        powerOn: Bool,
        skipColor: Bool = false,
        to accessoryID: UUID
    ) async throws {
        guard powerOn else {
            try await homeKitService.setPowerState(false, for: accessoryID)
            return
        }

        if brightness <= 0 {
            // Keep the bulb fully off at ramp start to avoid a flash at its last remembered level.
            try? await homeKitService.setBrightness(0, for: accessoryID)
            try await homeKitService.setPowerState(false, for: accessoryID)
            return
        }

        // Best effort: stage brightness/color before powering on so the bulb does not blink at its
        // previous level when the power state flips.
        try? await homeKitService.setBrightness(brightness, for: accessoryID)

        // Skip color writes to preserve Adaptive Lighting
        if !skipColor {
            // Color characteristics may not be available on white-only bulbs
            do {
                try await homeKitService.setHue(hue, for: accessoryID)
                try await homeKitService.setSaturation(saturation, for: accessoryID)
            } catch HomeKitServiceError.characteristicNotFound {
                // Light doesn't support color -- skip gracefully
            }
        }

        try await homeKitService.setPowerState(true, for: accessoryID)
        try await homeKitService.setBrightness(brightness, for: accessoryID)
    }

    func applyToMultipleLights(
        brightness: Int,
        hue: Double,
        saturation: Double,
        powerOn: Bool,
        skipColor: Bool = false,
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
                        skipColor: skipColor,
                        to: id
                    )
                }
            }
            try await group.waitForAll()
        }
    }

    func applyBestEffortToMultipleLights(
        brightness: Int,
        hue: Double,
        saturation: Double,
        powerOn: Bool,
        skipColor: Bool = false,
        identifiers: [UUID]
    ) async -> MultiLightWriteSummary {
        await withTaskGroup(of: Bool.self) { group in
            for id in identifiers {
                group.addTask {
                    do {
                        try await self.applyLightState(
                            brightness: brightness,
                            hue: hue,
                            saturation: saturation,
                            powerOn: powerOn,
                            skipColor: skipColor,
                            to: id
                        )
                        return true
                    } catch {
                        await MainActor.run {
                            self.log("Failed to apply light state to \(id): \(error)", level: .error)
                        }
                        return false
                    }
                }
            }

            var attempted = 0
            var succeeded = 0
            for await success in group {
                attempted += 1
                if success {
                    succeeded += 1
                }
            }

            return MultiLightWriteSummary(attempted: attempted, succeeded: succeeded)
        }
    }

    private func log(_ message: String, level: PhoneLogLevel = .info) {
        logStore.log("LightController", message, level: level)
    }
}
