//
//  AppearanceSettingsView.swift
//  Underbrim
//
//  Created by Richard Kunkli on 07/08/2024.
//

import Defaults
import SwiftUI

struct AppearanceSettingsView: View {
    @Default(.accentStyle) private var accentStyle
    @Default(.customAccentColorData) var customAccentColorData
    /// What the picker shows at once (the saved colour reaches the accent a pass later).
    @State private var customAccentColor: Color = PresetAccentColor.blue.color
    private var selectedPreset: PresetAccentColor? {
        PresetAccentColor.allCases.first { colorsAreEqual($0.color, customAccentColor) }
    }

    var body: some View {
        Form {
            accentColorSection
            notchSection
            MoreInAdvanced(.notch)
        }
        .navigationTitle("Appearance")
        .onAppear(perform: loadCustomColor)
    }

    private var accentColorSection: some View {
        Section {
            VStack(spacing: 12) {
                HStack(spacing: 22) {
                    ForEach(AccentStyle.allCases, id: \.self) { style in
                        AccentSwatch(title: style.title, detail: detail(of: style), color: style.swatch,
                                     isSelected: accentStyle == style) {
                            accentStyle = style
                        }
                    }
                }
                Text(detail(of: accentStyle))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityHidden(true)  // each card's hint says it
            }
            // Centred in the card, not over the description: its length changes with the choice.
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .onChange(of: accentStyle) {
                // The older setting, which earlier versions read: going back to one keeps Custom.
                Defaults[.useCustomAccentColor] = accentStyle == .custom
                guard accentStyle == .custom else { return }
                if customAccentColorData == nil { saveCustomColor(PresetAccentColor.blue.color) }
                loadCustomColor()
            }
            .settingsItem("Accent color")
            if accentStyle == .custom {
                customColors
            }
        } header: {
            SettingsPageHeader(tab: .appearance, section: "Accent color")
        }
    }

    private func detail(of style: AccentStyle) -> String {
        switch style {
        case .underbrim: String(localized: "The warm glow from Underbrim's icon.")
        case .system: String(localized: "Your Mac's accent color, as set in System Settings.")
        case .custom: String(localized: "A color you choose.")
        }
    }

    private var customColors: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Color Presets")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                ForEach(PresetAccentColor.allCases) { preset in
                    AccentCircleButton(
                        name: preset.title,
                        isSelected: selectedPreset == preset,
                        color: preset.color
                    ) {
                        customAccentColor = preset.color
                        saveCustomColor(preset.color)
                    }
                }
                Spacer()
            }

            Divider()
                .padding(.vertical, 4)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pick a Color")
                        .font(.body)
                    Text("Choose any color")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                ColorPicker("Pick a Color", selection: Binding(
                    get: { customAccentColor },
                    set: { newColor in
                        customAccentColor = newColor
                        saveCustomColor(newColor)
                    }
                ), supportsOpacity: false)
                .labelsHidden()
            }
        }
        .padding(.vertical, 4)
    }

    private var notchSection: some View {
        Section {
            Defaults.Toggle(key: .enableShadow) {
                Text("Shadow and edge light")
            }
            .settingsItem("Shadow and edge light")
            Defaults.Toggle(key: .showNotHumanFace) {
                SettingsLabel("A face when idle", info: "In the closed notch when nothing's playing.")
            }
            .settingsItem("A face when idle")
        } header: {
            Text("Notch")
        }
    }

    private func saveCustomColor(_ color: Color) {
        let nsColor = NSColor(color)
        if let colorData = try? NSKeyedArchiver.archivedData(withRootObject: nsColor, requiringSecureCoding: false) {
            Defaults[.customAccentColorData] = colorData
        }
    }

    private func loadCustomColor() {
        if let saved = AccentColor.saved { customAccentColor = Color(nsColor: saved) }
    }

    private func colorsAreEqual(_ color1: Color, _ color2: Color) -> Bool {
        let nsColor1 = NSColor(color1).usingColorSpace(.sRGB) ?? NSColor(color1)
        let nsColor2 = NSColor(color2).usingColorSpace(.sRGB) ?? NSColor(color2)

        return abs(nsColor1.redComponent - nsColor2.redComponent) < 0.01 &&
               abs(nsColor1.greenComponent - nsColor2.greenComponent) < 0.01 &&
               abs(nsColor1.blueComponent - nsColor2.blueComponent) < 0.01
    }
}

/// An accent as the colour it gives the notch, ringed when chosen, its name under it.
private struct AccentSwatch: View {
    let title: String
    let detail: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Circle()
                    .fill(color)
                    .overlay { Circle().strokeBorder(.black.opacity(contrast == .increased ? 0.45 : 0.12)) }
                    .frame(width: 30, height: 30)
                    .padding(4)
                    .overlay { if isSelected { Circle().strokeBorder(Color.accentText, lineWidth: 2) } }
                // As wide as when chosen (bold), so choosing one moves none of them.
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .hidden()
                    .overlay {
                        Text(title)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? .primary : .secondary)
                            .fixedSize()
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension AccentStyle {
    var title: String {
        switch self {
        case .underbrim: "Underbrim"
        case .system: String(localized: "System")
        case .custom: String(localized: "Custom")
        }
    }

    @MainActor var swatch: Color {
        switch self {
        case .underbrim: Color(nsColor: .underbrimGlow)
        case .system: Color(nsColor: AccentColor.onBlack(.controlAccentColor))
        // Custom starts on blue until a colour is saved.
        case .custom: Color(nsColor: AccentColor.onBlack(AccentColor.saved ?? NSColor(PresetAccentColor.blue.color)))
        }
    }
}

// MARK: - Accent color presets

/// macOS-style accent color presets for Custom (Underbrim's own colour is its own choice).
enum PresetAccentColor: String, CaseIterable, Identifiable {
    case blue = "Blue"
    case purple = "Purple"
    case pink = "Pink"
    case red = "Red"
    case orange = "Orange"
    case yellow = "Yellow"
    case green = "Green"
    case graphite = "Graphite"

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .blue: String(localized: "Blue")
        case .purple: String(localized: "Purple")
        case .pink: String(localized: "Pink")
        case .red: String(localized: "Red")
        case .orange: String(localized: "Orange")
        case .yellow: String(localized: "Yellow")
        case .green: String(localized: "Green")
        case .graphite: String(localized: "Graphite")
        }
    }

    var color: Color {
        switch self {
        case .blue: return Color(red: 0.0, green: 0.478, blue: 1.0)
        case .purple: return Color(red: 0.686, green: 0.322, blue: 0.871)
        case .pink: return Color(red: 1.0, green: 0.176, blue: 0.333)
        case .red: return Color(red: 1.0, green: 0.271, blue: 0.227)
        case .orange: return Color(red: 1.0, green: 0.584, blue: 0.0)
        case .yellow: return Color(red: 1.0, green: 0.8, blue: 0.0)
        case .green: return Color(red: 0.4, green: 0.824, blue: 0.176)
        case .graphite: return Color(red: 0.557, green: 0.557, blue: 0.576)
        }
    }
}

// MARK: - Accent Circle Button Component
struct AccentCircleButton: View {
    /// What VoiceOver and the tooltip call it.
    let name: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // Color circle
                Circle()
                    .fill(color)
                    .frame(width: 32, height: 32)

                // Subtle border
                Circle()
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    .frame(width: 32, height: 32)

                // Apple-style highlight ring around the middle when selected
                if isSelected {
                    Circle()
                        .strokeBorder(
                            Color.white.opacity(0.5),
                            lineWidth: 2
                        )
                        .frame(width: 28, height: 28)
                }
            }
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
