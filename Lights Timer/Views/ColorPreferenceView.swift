import SwiftUI

struct ColorPreferenceView: View {
    @Binding var startHue: Double
    @Binding var startSaturation: Double
    @Binding var startBrightness: Double
    @Binding var endHue: Double
    @Binding var endSaturation: Double
    @Binding var endBrightness: Double

    private var startColor: Color {
        Color(hue: startHue, saturation: startSaturation, brightness: startBrightness)
    }

    private var endColor: Color {
        Color(hue: endHue, saturation: endSaturation, brightness: endBrightness)
    }

    var body: some View {
        Section {
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [startColor, endColor],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 48)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.quaternary, lineWidth: 1)
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            ColorPicker("Start Color (warm)", selection: Binding(
                get: { startColor },
                set: { newColor in
                    let hsb = newColor.hsb
                    startHue = hsb.hue
                    startSaturation = hsb.saturation
                    startBrightness = hsb.brightness
                }
            ), supportsOpacity: false)

            ColorPicker("End Color (cool)", selection: Binding(
                get: { endColor },
                set: { newColor in
                    let hsb = newColor.hsb
                    endHue = hsb.hue
                    endSaturation = hsb.saturation
                    endBrightness = hsb.brightness
                }
            ), supportsOpacity: false)
        } header: {
            Label("Light Colors", systemImage: "paintpalette")
        } footer: {
            Text("The light gradually transitions from the start color to the end color over the lead time.")
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
    Form {
        ColorPreferenceView(
            startHue: $sH, startSaturation: $sS, startBrightness: $sB,
            endHue: $eH, endSaturation: $eS, endBrightness: $eB
        )
    }
}
