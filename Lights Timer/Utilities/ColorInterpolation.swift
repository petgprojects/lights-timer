import Foundation

func interpolateHSB(
    startHue: Double,
    startSat: Double,
    startBri: Double,
    endHue: Double,
    endSat: Double,
    endBri: Double,
    progress: Double
) -> (hue: Double, saturation: Double, brightness: Double) {
    let t = min(max(progress, 0), 1)

    // Hue wrapping: take the shortest path around the color wheel
    var deltaHue = endHue - startHue
    if deltaHue > 0.5 {
        deltaHue -= 1.0
    } else if deltaHue < -0.5 {
        deltaHue += 1.0
    }
    var hue = startHue + deltaHue * t
    if hue < 0 { hue += 1.0 }
    if hue > 1 { hue -= 1.0 }

    let saturation = startSat + (endSat - startSat) * t
    let brightness = startBri + (endBri - startBri) * t

    return (hue: hue, saturation: saturation, brightness: brightness)
}

func interpolateBrightness(target: Int, progress: Double) -> Int {
    let t = min(max(progress, 0), 1)
    return Int(Double(target) * t)
}
