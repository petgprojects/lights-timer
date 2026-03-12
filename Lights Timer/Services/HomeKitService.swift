import Foundation
import HomeKit

@Observable
final class HomeKitService: NSObject, HMHomeManagerDelegate {
    var homes: [HMHome] = []
    var availableLights: [HMAccessory] = []
    var isAuthorized: Bool = false
    var errorMessage: String?
    var onHomesUpdated: (() -> Void)?

    private let homeManager: HMHomeManager

    override init() {
        homeManager = HMHomeManager()
        super.init()
        homeManager.delegate = self
    }

    /// Waits for HomeKit homes to be available. Returns immediately if already ready.
    /// Times out after the specified interval to avoid blocking indefinitely.
    func waitForReady(timeout: TimeInterval = 10) async {
        if !homes.isEmpty { return }

        // Poll for readiness — HMHomeManager fires its delegate on main thread
        let deadline = Date().addingTimeInterval(timeout)
        while homes.isEmpty && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: - HMHomeManagerDelegate

    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        MainActor.assumeIsolated {
            homes = manager.homes
            isAuthorized = true
            refreshLights()
            onHomesUpdated?()
        }
    }

    // MARK: - Light Discovery

    private func refreshLights() {
        availableLights = homes.flatMap { home in
            home.accessories.filter { accessory in
                accessory.services.contains { $0.serviceType == HMServiceTypeLightbulb }
            }
        }
    }

    // MARK: - Light Control

    func setBrightness(_ value: Int, for accessoryID: UUID) async throws {
        let characteristic = try findCharacteristic(
            type: HMCharacteristicTypeBrightness,
            for: accessoryID
        )
        try await writeValue(value, for: characteristic)
    }

    func setHue(_ value: Double, for accessoryID: UUID) async throws {
        let characteristic = try findCharacteristic(
            type: HMCharacteristicTypeHue,
            for: accessoryID
        )
        try await writeValue(value, for: characteristic)
    }

    func setSaturation(_ value: Double, for accessoryID: UUID) async throws {
        let characteristic = try findCharacteristic(
            type: HMCharacteristicTypeSaturation,
            for: accessoryID
        )
        try await writeValue(value, for: characteristic)
    }

    func setPowerState(_ on: Bool, for accessoryID: UUID) async throws {
        let characteristic = try findCharacteristic(
            type: HMCharacteristicTypePowerState,
            for: accessoryID
        )
        try await writeValue(on, for: characteristic)
    }

    // MARK: - Helpers

    private func findCharacteristic(type: String, for accessoryID: UUID) throws -> HMCharacteristic {
        guard let accessory = availableLights.first(where: { $0.uniqueIdentifier == accessoryID }) else {
            throw HomeKitServiceError.accessoryNotFound
        }

        guard let service = accessory.services.first(where: { $0.serviceType == HMServiceTypeLightbulb }) else {
            throw HomeKitServiceError.serviceNotFound
        }

        guard let characteristic = service.characteristics.first(where: { $0.characteristicType == type }) else {
            throw HomeKitServiceError.characteristicNotFound
        }

        return characteristic
    }

    private func writeValue(_ value: Any, for characteristic: HMCharacteristic) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            characteristic.writeValue(value) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

enum HomeKitServiceError: LocalizedError {
    case accessoryNotFound
    case serviceNotFound
    case characteristicNotFound

    var errorDescription: String? {
        switch self {
        case .accessoryNotFound: "Light accessory not found"
        case .serviceNotFound: "Lightbulb service not found"
        case .characteristicNotFound: "Characteristic not found on light"
        }
    }
}
