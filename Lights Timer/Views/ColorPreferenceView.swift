import SwiftUI

struct ColorPreferenceView: View {
    @Binding var startHue: Double
    @Binding var startSaturation: Double
    @Binding var startBrightness: Double
    @Binding var endHue: Double
    @Binding var endSaturation: Double
    @Binding var endBrightness: Double
    @Binding var startIsAdaptive: Bool
    @Binding var endIsAdaptive: Bool

    private var startColor: Color {
        Color(hue: startHue, saturation: startSaturation, brightness: startBrightness)
    }

    private var endColor: Color {
        Color(hue: endHue, saturation: endSaturation, brightness: endBrightness)
    }

    /// Warm-white to cool-white gradient representing Adaptive Lighting
    private static let adaptiveGradient = LinearGradient(
        colors: [
            Color(hue: 0.08, saturation: 0.3, brightness: 1.0),
            Color(hue: 0.55, saturation: 0.15, brightness: 1.0)
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    private var previewGradient: some View {
        let leftColor = startIsAdaptive
            ? Color(hue: 0.08, saturation: 0.3, brightness: 1.0)
            : startColor
        let rightColor = endIsAdaptive
            ? Color(hue: 0.55, saturation: 0.15, brightness: 1.0)
            : endColor

        return RoundedRectangle(cornerRadius: 12)
            .fill(
                LinearGradient(
                    colors: [leftColor, rightColor],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 48)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
            .overlay {
                if startIsAdaptive || endIsAdaptive {
                    HStack {
                        if startIsAdaptive {
                            Label("Adaptive", systemImage: "sun.horizon")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if endIsAdaptive {
                            Label("Adaptive", systemImage: "sun.horizon")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
    }

    var body: some View {
        Section {
            previewGradient
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            Toggle("Start: Adaptive Lighting", isOn: $startIsAdaptive)
                .tint(.orange)

            if !startIsAdaptive {
                ColorPicker("Start Color (warm)", selection: Binding(
                    get: { startColor },
                    set: { newColor in
                        let hsb = newColor.hsb
                        startHue = hsb.hue
                        startSaturation = hsb.saturation
                        startBrightness = hsb.brightness
                    }
                ), supportsOpacity: false)
            }

            Toggle("End: Adaptive Lighting", isOn: $endIsAdaptive)
                .tint(.orange)

            if !endIsAdaptive {
                ColorPicker("End Color (cool)", selection: Binding(
                    get: { endColor },
                    set: { newColor in
                        let hsb = newColor.hsb
                        endHue = hsb.hue
                        endSaturation = hsb.saturation
                        endBrightness = hsb.brightness
                    }
                ), supportsOpacity: false)
            }
        } header: {
            Label("Light Colors", systemImage: "paintpalette")
        } footer: {
            if startIsAdaptive || endIsAdaptive {
                Text("Adaptive Lighting lets your lights automatically adjust color temperature throughout the day. When selected, only brightness is changed during the ramp so Adaptive Lighting stays active.")
            } else {
                Text("The light gradually transitions from the start color to the end color over the lead time.")
            }
        }
    }
}

// MARK: - Color HSB Extraction

extension Color {
    var hsb: (hue: Double, saturation: Double, brightness: Double) {
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        let uiColor = UIColor(self)
        uiColor.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (Double(h), Double(s), Double(b))
    }
}

#Preview {
    @Previewable @State var sH = 0.08
    @Previewable @State var sS = 1.0
    @Previewable @State var sB = 1.0
    @Previewable @State var eH = 0.0
    @Previewable @State var eS = 0.0
    @Previewable @State var eB = 1.0
    @Previewable @State var sA = false
    @Previewable @State var eA = false
    Form {
        ColorPreferenceView(
            startHue: $sH, startSaturation: $sS, startBrightness: $sB,
            endHue: $eH, endSaturation: $eS, endBrightness: $eB,
            startIsAdaptive: $sA, endIsAdaptive: $eA
        )
    }
}
