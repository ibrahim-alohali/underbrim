//
//  WebcamView.swift
//  Underbrim
//
//  Created by Harsh Vardhan  Goswami  on 19/08/24.
//

import AVFoundation
import Defaults
import SwiftUI

struct CameraPreviewView: View {
    let camera: CameraModel
    /// The island it's in: the camera is its until it closes.
    var island: NotchViewModel?
    /// Its side (it's square). Home passes its row height.
    var side: CGFloat = 130
    @Default(.isMirrored) private var isMirrored

    private var mirrorSide: CGFloat { side }

    private var mirrorCornerRadius: CGFloat {
        Defaults[.mirrorShape] == .rectangle ? NotchMetrics.innerRadius : mirrorSide / 2
    }

    var body: some View {
        ZStack {
            if let session = camera.activeSession {
                CameraPreviewLayerView(
                    session: session,
                    isMirrored: isMirrored
                )
                .frame(width: mirrorSide, height: mirrorSide)
                .clipShape(RoundedRectangle(cornerRadius: mirrorCornerRadius))
                .opacity(camera.isSessionRunning ? 1 : 0)
            }

            if !camera.isSessionRunning {
                ZStack {
                    RoundedRectangle(cornerRadius: mirrorCornerRadius)
                        .fill(Color(red: 20/255, green: 20/255, blue: 20/255))
                        .strokeBorder(.white.opacity(0.04), lineWidth: 1)
                        .frame(width: mirrorSide, height: mirrorSide)
                    VStack(spacing: 8) {
                        Image(systemName: camera.state == .permissionDenied ? "exclamationmark.triangle" : "web.camera")
                            .foregroundStyle(.gray)
                            .font(.system(size: mirrorSide / 3.5))
                        Text(mirrorPlaceholderTitle)
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }
            }
        }
        .frame(width: mirrorSide, height: mirrorSide)
        // The island's own toggle, as its Mirror button uses, so both behave alike.
        .onTapGesture { island?.toggleCameraPreview() }
        .allowsHitTesting(camera.state != .unavailable)
    }

    private var mirrorPlaceholderTitle: String {
        switch camera.state {
        case .permissionDenied:
            NSLocalizedString("Access Denied", comment: "Camera permission placeholder title")
        case .interrupted:
            NSLocalizedString("Paused", comment: "Camera interrupted placeholder title")
        case .unavailable:
            NSLocalizedString("No Camera", comment: "No camera available placeholder title")
        default:
            NSLocalizedString("Mirror", comment: "Camera mirror placeholder title")
        }
    }
}

/// AppKit-native preview: owns its own `AVCaptureVideoPreviewLayer` as a
/// sublayer and keeps mirroring at the capture-connection level so SwiftUI
/// transforms are not involved.
struct CameraPreviewLayerView: NSViewRepresentable {
    let session: AVCaptureSession
    let isMirrored: Bool

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView()
        view.attach(session: session, isMirrored: isMirrored)
        return view
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.attach(session: session, isMirrored: isMirrored)
    }

    func dismantleNSView(_ nsView: CameraPreviewNSView, coordinator: ()) {
        nsView.detach()
    }
}

final class CameraPreviewNSView: NSView {
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The backing layer must exist before `attach` adds the preview
        // sublayer, otherwise addSublayer silently no-ops and nothing renders.
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Re-apply in case the view was moved into a window after attaching;
        // also fixes frames set while detached.
        if previewLayer != nil {
            layoutPreview()
        }
    }

    override func layout() {
        super.layout()
        layoutPreview()
    }

    func attach(session: AVCaptureSession, isMirrored: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if let previewLayer, previewLayer.session === session {
            applyMirroring(isMirrored, to: previewLayer)
            layoutPreview()
            return
        }

        previewLayer?.removeFromSuperlayer()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.frame = bounds
        self.layer?.addSublayer(layer)
        previewLayer = layer

        applyMirroring(isMirrored, to: layer)
    }

    func detach() {
        previewLayer?.removeFromSuperlayer()
        previewLayer = nil
    }

    private func layoutPreview() {
        guard let previewLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }

    /// Mirroring belongs to the capture connection, not the view hierarchy.
    private func applyMirroring(_ isMirrored: Bool, to layer: AVCaptureVideoPreviewLayer) {
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            // Preview connections are front-facing-mirrored by default; align
            // the presentation with the user's "Flip video" preference.
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = isMirrored
        }
    }
}

#Preview {
    CameraPreviewView(camera: CameraModel())
}
