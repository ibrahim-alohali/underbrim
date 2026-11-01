//
//  MediaSettingsView.swift
//  Underbrim
//
//  Created by Richard Kunkli on 07/08/2024.
//

import Defaults
import SwiftUI

struct MediaSettingsView: View {
    @ObservedObject var coordinator = NotchViewCoordinator.shared
    @Default(.enableSneakPeek) private var enableSneakPeek
    @Default(.sneakPeekStyles) var sneakPeekStyles

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Show what's playing when the notch is closed",
                    isOn: $coordinator.musicLiveActivityEnabled.animation()
                )
                .settingsItem("Show what's playing when the notch is closed")
                Toggle(isOn: $enableSneakPeek) {
                    SettingsLabel("Show sneak peek on playback changes",
                                  info: "Sneak Peek shows the media title and artist under the notch for a few seconds.")
                }
                .settingsItem("Show sneak peek on playback changes")
                Picker("Sneak Peek Style", selection: $sneakPeekStyles) {
                    ForEach(SneakPeekStyle.allCases) { style in
                        Text(style.localizedString).tag(style)
                    }
                }
                .settingsItem("Sneak Peek Style")
            } header: {
                SettingsPageHeader(tab: .media, section: "Media playback live activity")
            }

            Section {
                MusicSlotConfigurationView()
                    .settingsItem("Media controls")
            } header: {
                SettingsLabel("Media controls", info: "Customize which controls appear in the media player. Volume expands when active.")
            }

            MoreInAdvanced(.media)
        }
        .navigationTitle("Media")
    }
}

/// Advanced › Media: where it comes from, when the player hides, its look, and the Sneak Peek shortcut.
struct MediaAdvancedSettings: View {
    @Default(.waitInterval) var waitInterval
    @Default(.hideNotchOption) var hideNotchOption
    @Default(.sliderColor) var sliderColor

    @ObservedObject private var musicManager = MusicManager.shared

    private var realtimeAudioWaveformSupported: Bool {
        if #available(macOS 14.2, *) {
            return true
        }
        return false
    }

    var body: some View {
        Section {
            Picker("Media Source", selection: mediaControllerSelection) {
                ForEach(MediaControllerType.allCases) { controller in
                    Text(controller.localizedResource)
                        .tag(controller)
                        .disabled(
                            controller == .nowPlaying
                                && !musicManager.nowPlayingAvailability.isSelectable
                        )
                }
            }
            .settingsItem("Media Source")
        } header: {
            AdvancedHeader(area: .media)
        } footer: {
            mediaSourceFooter
        }
        .task {
            musicManager.ensureNowPlayingAvailabilityChecked()
        }

        Section {
            HStack {
                Stepper(value: $waitInterval, in: 0...10, step: 1) {
                    HStack {
                        Text("Media inactivity timeout")
                        Spacer()
                        Text(
                            Measurement(
                                value: Defaults[.waitInterval],
                                unit: UnitDuration.seconds
                            ),
                            format: .measurement(
                                width: .wide,
                                usage: .asProvided,
                                numberFormatStyle: .number.precision(
                                    .fractionLength(0)
                                )
                            )
                        )
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .settingsItem("Media inactivity timeout")
            Picker(
                selection: $hideNotchOption,
                label:
                    HStack {
                        Text("Full screen behavior")
                        customBadge(text: "Beta")
                    }
            ) {
                Text("Hide for all apps").tag(HideNotchOption.always)
                Text("Hide for media app only").tag(
                    HideNotchOption.nowPlayingOnly)
                Text("Never hide").tag(HideNotchOption.never)
            }
            .settingsItem("Full screen behavior")
            ShortcutRecorderRow(title: "Toggle Sneak Peek", mark: "Toggle Sneak Peek", name: .toggleSneakPeek)
        }

        Section {
            Defaults.Toggle(key: .showRemainingTime) {
                Text("Show remaining time instead of duration")
            }
            .settingsItem("Show remaining time instead of duration")
            Defaults.Toggle(key: .coloredSpectrogram) {
                Text("Colored spectrogram")
            }
            .settingsItem("Colored spectrogram")
            Defaults.Toggle(key: .realtimeAudioWaveform) {
                if realtimeAudioWaveformSupported {
                    SettingsLabel("Real-time audio waveform",
                                  info: "Uses Accelerate FFT on the playing app's audio. Requires audio capture permission and uses slightly more CPU.")
                } else {
                    Text("Real-time audio waveform")
                    Text("Requires macOS 14.2 or later. Update macOS to enable real-time audio waveform.")
                }
            }
            .settingsItem("Real-time audio waveform")
            .disabled(!realtimeAudioWaveformSupported)
            Defaults.Toggle(key: .playerColorTinting) {
                Text("Player tinting")
            }
            .settingsItem("Player tinting")
            Defaults.Toggle(key: .lightingEffect) {
                Text("Enable blur effect behind album art")
            }
            .settingsItem("Enable blur effect behind album art")
            Picker("Slider color", selection: $sliderColor) {
                ForEach(SliderColorEnum.allCases, id: \.self) { option in
                    Text(option.localizedString)
                }
            }
            .settingsItem("Slider color")
        } header: {
            Text("Player appearance")
        }
    }

    private var mediaControllerSelection: Binding<MediaControllerType> {
        Binding(
            get: { musicManager.preferredMediaController },
            set: { selectedController in
                guard selectedController != musicManager.preferredMediaController else { return }
                musicManager.selectMediaController(selectedController)
            }
        )
    }

    @ViewBuilder
    private var mediaSourceFooter: some View {
        let availability = musicManager.nowPlayingAvailability

        if availability == .checking {
            footerText("Checking Now Playing availability...")
        } else if let message = availability.settingsMessage {
            VStack(alignment: .leading, spacing: 6) {
                footerText(message)

                if musicManager.preferredMediaController == .nowPlaying,
                   let effectiveController = musicManager.effectiveMediaController,
                   effectiveController != .nowPlaying {
                    if availability.usesTemporaryFallback {
                        footerText(
                            LocalizedStringResource(
                                "Using \(effectiveController.localizedString) temporarily. Your Now Playing preference is preserved.",
                                comment: "Media settings footer for a temporary Now Playing fallback. The placeholder is the active fallback source."
                            )
                        )
                    } else {
                        footerText(
                            LocalizedStringResource(
                                "Using \(effectiveController.localizedString) instead. Your Now Playing preference is preserved.",
                                comment: "Media settings footer for a non-recoverable Now Playing setup failure. The placeholder is the active fallback source."
                            )
                        )
                    }
                }

                if availability.offersManualRetry {
                    Button("Check Again") {
                        musicManager.refreshNowPlayingAvailability()
                    }
                    .font(.caption)
                }
            }
        } else {
            footerText(
                "Now Playing works with any app that plays sound or video, browsers included."
            )
        }
    }

    private func footerText(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .font(.caption)
    }
}
