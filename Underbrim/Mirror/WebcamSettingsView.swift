//
//  WebcamSettingsView.swift
//  Underbrim
//
//  Created by Anmol Malhotra on 2026-02-24.
//

import SwiftUI
import Defaults

/// Widgets › Mirror: how the mirror shows, while it's on (in the widget list above).
struct MirrorSettingsSection: View {
    @Default(.showMirror) private var showMirror
    @Default(.mirrorShape) private var mirrorShape
    let camera: CameraModel

    var body: some View {
        if showMirror {
            section
        }
    }

    private var section: some View {
        Section {
            Defaults.Toggle(key: .isMirrored) {
                Text("Flip video")
            }
            .settingsItem("Flip video")
            .disabled(!camera.cameraAvailable)
            .onAppear { camera.refresh() }

            Picker("Camera", selection: Binding(
                get: { camera.selection },
                set: { camera.selectCamera($0) }
            )) {
                Text("Automatic")
                    .tag(CameraSelection.automatic)
                ForEach(camera.availableCameras) { device in
                    Text(device.name)
                        .tag(CameraSelection.device(device.id))
                }
            }
            .disabled(!camera.cameraAvailable)
            .settingsItem("Camera")

            Picker("Frame shape", selection: $mirrorShape) {
                Text("Circle")
                    .tag(MirrorShapeEnum.circle)
                Text("Square")
                    .tag(MirrorShapeEnum.rectangle)
            }
            .disabled(!camera.cameraAvailable)
            .settingsItem("Frame shape")
        } header: {
            Text("Mirror")
        }
    }
}
