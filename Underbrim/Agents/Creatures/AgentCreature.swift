//
//  AgentCreature.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  A small creature per coding agent, in its maker's style, acting out its session: a
//  loop while it works, a question or alert while it waits on you (then still), a short
//  reaction when it ends. Drawn as cubes (VoxelArt) at 12 fps on the display's clock, only
//  while it moves; still with Reduce Motion. The state symbol and words still say it.
//

import AppKit
import SwiftUI

/// Whose creature: one per agent, a plain one for any other.
enum AgentCreatureKind: CaseIterable, Hashable, Sendable {
    case agent(AgentProvider)
    case other

    static var allCases: [AgentCreatureKind] { AgentProvider.allCases.map(Self.agent) + [.other] }

    init(provider: AgentProvider) { self = .agent(provider) }

    var creature: any AgentCreature {
        switch self {
        case .agent(.claude): TerraCreature()
        case .agent(.codex): MoteCreature()
        case .agent(.cursor): SlabCreature()
        case .agent(.antigravity): LiltCreature()
        case .agent(.qwen): GlintCreature()
        case .agent(.qoder): QoderCreature()
        case .other: PlainCreature()
        }
    }

    /// Its name in the rendered sounds' file names ("claude-done-60"), kept as it was.
    var soundName: String {
        switch self {
        case .agent(let provider): provider.rawValue
        case .other: "other"
        }
    }
}

enum AgentCreatureState: Equatable, Sendable {
    case idle, working
    /// Waiting on you: it asked a question, or wants your go-ahead (a tool to run, a plan).
    case question, permission
    case done, failed
    case stopped
}

enum CreatureCue: CaseIterable, Sendable {
    /// Waiting on you (and the one reminder after a while).
    case attention, done, failed
}

struct CreatureFrame {
    var state: AgentCreatureState
    /// Seconds since the session took this state, a whole number of frames.
    var elapsed: TimeInterval
    /// Draw the pose the state holds: with Reduce Motion, after its motion, or on a card.
    var still: Bool
}

protocol AgentCreature: Sendable {
    /// Its box in points at full size; the closed notch shows it 20 pt tall.
    var box: CGSize { get }
    /// How far it may draw outside its box (a hop, a ripple), in the same points.
    var overflow: CGFloat { get }
    func frameInterval(_ state: AgentCreatureState) -> TimeInterval
    /// How long a state moves before it holds its pose; nil: for as long as the state lasts.
    func motionLength(_ state: AgentCreatureState) -> TimeInterval?
    func render(_ frame: CreatureFrame) -> CreatureImage
    func sound(_ cue: CreatureCue) -> (graph: SynthGraph, output: SynthGraph.Node, seconds: Double)
}

extension AgentCreature {
    var canvas: CreatureCanvas { CreatureCanvas(box: box, overflow: overflow) }
    func frameInterval(_ state: AgentCreatureState) -> TimeInterval { CreatureClock.step }
}

struct AgentCreatureView: View {
    let kind: AgentCreatureKind
    let state: AgentCreatureState
    /// When the session took this state: a finished one celebrates once, then stands.
    var since: Date = .distantPast
    var height: CGFloat = 20
    var movesOnlyWhileWorking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let creature = kind.creature
        let scale = height / creature.box.height
        let margin = creature.overflow * scale
        CreatureLayer(look: .init(kind: kind, state: state, since: since, height: height,
                                  movesOnlyWhileWorking: movesOnlyWhileWorking, reduceMotion: reduceMotion))
            .frame(width: creature.box.width * scale + 2 * margin, height: height + 2 * margin)
            .frame(width: creature.box.width * scale, height: height)
            .accessibilityHidden(true)
    }
}

/// The creature in a layer of its own: drawn by SwiftUI, each frame re-laid out and rendered
/// the whole notch window, a tenth of a core for as long as a session works.
private struct CreatureLayer: NSViewRepresentable {
    let look: CreatureLayerView.Look

    func makeNSView(context: Context) -> CreatureLayerView { CreatureLayerView() }
    func updateNSView(_ view: CreatureLayerView, context: Context) { view.show(look) }
}

private final class CreatureLayerView: NSView {
    struct Look: Equatable {
        let kind: AgentCreatureKind
        let state: AgentCreatureState
        let since: Date
        let height: CGFloat
        let movesOnlyWhileWorking: Bool
        let reduceMotion: Bool
    }

    private var look: Look?
    private let image = CALayer()
    private var link: CADisplayLink?
    /// The display's time of the link's first frame, and that frame's number.
    private var start: (time: CFTimeInterval, frame: Int)?
    private var shown: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Whole device pixels per art pixel, not smoothed.
        image.magnificationFilter = .nearest
        image.minificationFilter = .nearest
        image.contentsGravity = .resize
        layer?.addSublayer(image)
    }

    required init?(coder: NSCoder) { nil }

    /// Clicks and hovers go to the card or notch under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ look: Look) {
        guard look != self.look else { return }
        self.look = look
        place()
        restart()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Removed with the view too, should its window go first.
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        place()
        restart()
    }

    @objc private func occlusionChanged(_ notification: Notification) { restart() }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        place()
    }

    override func layout() {
        super.layout()
        place()
    }

    /// Draws now, and keeps drawing while it moves; nothing runs while it stands or can't be seen.
    private func restart() {
        link?.invalidate()
        link = nil
        start = nil
        shown = nil
        let number = frame(at: .now), moves = moving(number)
        draw(number, still: !moves)
        guard let look, moves, window?.occlusionState.contains(.visible) == true else { return }
        let link = displayLink(target: CreatureTicker(self), selector: #selector(CreatureTicker.tick(_:)))
        let rate = Float(1 / look.kind.creature.frameInterval(look.state))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// A frame of the display: counted from the link's first, so frames come evenly however the
    /// state's start falls between them.
    fileprivate func tick(_ link: CADisplayLink) {
        guard let look else { return }
        let step = look.kind.creature.frameInterval(look.state)
        let start = self.start ?? (link.targetTimestamp, frame(at: .now))
        self.start = start
        let number = start.frame + Int(((link.targetTimestamp - start.time) / step).rounded())
        guard moving(number) else {
            self.link?.invalidate()
            self.link = nil
            return draw(number, still: true)
        }
        if number != shown { draw(number, still: false) }
    }

    /// Whether a frame moves: by its number, so the last one shown is the motion's last, whatever
    /// the display's clock does against the wall clock.
    private func moving(_ number: Int) -> Bool {
        guard let look, look.height > 0, !look.reduceMotion else { return false }
        if look.movesOnlyWhileWorking, look.state != .working { return false }
        guard let length = look.kind.creature.motionLength(look.state) else { return true }
        return Double(number) * look.kind.creature.frameInterval(look.state) < length - 1e-6
    }

    /// The frame for a moment: for a state of unknown start, a running count (loops only need its phase).
    private func frame(at date: Date) -> Int {
        guard let look else { return 0 }
        let elapsed = look.since == .distantPast ? date.timeIntervalSinceReferenceDate : max(0, date.timeIntervalSince(look.since))
        return Int((elapsed / look.kind.creature.frameInterval(look.state) + 1e-6).rounded(.down))
    }

    /// The canvas at whole device pixels per art pixel, its floor on the box's bottom edge, centred.
    private func place() {
        guard let look, let window else { return }
        let creature = look.kind.creature, canvas = creature.canvas
        let scale = look.height / creature.box.height
        let backing = max(1, window.backingScaleFactor)
        // The nearest whole number of device pixels, but none that makes it much larger than its box
        // (at full size on a 1x screen, 1 pt: a little smaller).
        let exact = CreatureCanvas.unit * scale * backing, whole = exact.rounded()
        let pixel = max(1, whole > exact * 1.1 ? whole - 1 : whole) / backing
        let size = CGSize(width: CGFloat(canvas.columns) * pixel, height: CGFloat(canvas.rows) * pixel)
        let floor = creature.overflow * scale
        let x = ((bounds.midX - size.width / 2) * backing).rounded() / backing
        let y = ((floor - CGFloat(canvas.rows - canvas.floor) * pixel) * backing).rounded() / backing
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        image.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        image.contentsScale = backing
        CATransaction.commit()
    }

    private func draw(_ number: Int, still: Bool) {
        guard let look else { return }
        let creature = look.kind.creature
        let frame = CreatureFrame(state: look.state, elapsed: Double(number) * creature.frameInterval(look.state), still: still)
        // Nothing where it has no room (the closed notch hidden over a full-screen app).
        let picture = look.height > 0 ? creature.render(frame).makeImage() : nil
        shown = still ? nil : number
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        image.contents = picture
        CATransaction.commit()
    }
}

/// The display link's target: it holds its target strongly, so this holds the view weakly.
private final class CreatureTicker: NSObject {
    private weak var view: CreatureLayerView?

    init(_ view: CreatureLayerView) { self.view = view }

    /// The link was added to the main run loop, so this runs on the main thread.
    @MainActor @objc func tick(_ link: CADisplayLink) {
        guard let view else { return link.invalidate() }
        view.tick(link)
    }
}
