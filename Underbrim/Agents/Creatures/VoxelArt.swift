//
//  VoxelArt.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  How the creatures are drawn: models of coloured cubes turned about their upright axis,
//  in square pixels of 1.5 pt at full size, lit from just above the viewer with shades in
//  steps so a small turn doesn't shimmer. A frame is a few hundred pixels made on the CPU.
//

import CoreGraphics
import Foundation

struct PixelColor: Equatable, Sendable {
    var r: Double, g: Double, b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    func scaled(_ factor: Double) -> PixelColor {
        PixelColor(min(255, r * factor), min(255, g * factor), min(255, b * factor))
    }

    func mixed(with other: PixelColor, _ amount: Double) -> PixelColor {
        let u = min(1, max(0, amount))
        return PixelColor(r + (other.r - r) * u, g + (other.g - g) * u, b + (other.b - b) * u)
    }

    /// Its grey of the same lightness, a little cooler, for a creature gone dim.
    var greyed: PixelColor {
        let level = 0.3 * r + 0.59 * g + 0.11 * b
        return PixelColor(level * 0.82 + 18, level * 0.84 + 20, level * 0.88 + 30)
    }
}

/// The pixels a creature draws on: its box with room around it. The floor is the box's bottom edge.
struct CreatureCanvas: Equatable, Sendable {
    static let unit: CGFloat = 1.5
    let columns: Int, rows: Int
    /// Rows above the floor: a figure standing on it ends on the row above this index.
    let floor: Int

    init(box: CGSize, overflow: CGFloat) {
        columns = Int(((box.width + 2 * overflow) / Self.unit).rounded())
        rows = Int(((box.height + 2 * overflow) / Self.unit).rounded(.down))
        floor = rows - Int((overflow / Self.unit).rounded())
    }

    /// The column at the box's middle, rounded to the left for an even model on an odd canvas.
    var middle: Int { columns / 2 }
}

/// A frame: art pixels, premultiplied red, green, blue and alpha, row by row from the top.
struct CreatureImage: Equatable {
    let columns: Int, rows: Int
    private(set) var bytes: [UInt8]

    init(_ canvas: CreatureCanvas) {
        columns = canvas.columns
        rows = canvas.rows
        bytes = [UInt8](repeating: 0, count: canvas.columns * canvas.rows * 4)
    }

    mutating func set(_ x: Int, _ y: Int, _ color: PixelColor, alpha: Double = 1) {
        guard x >= 0, y >= 0, x < columns, y < rows, alpha > 0 else { return }
        let a = min(1, alpha), i = (y * columns + x) * 4
        let keep = 1 - a
        bytes[i] = UInt8((color.r * a + Double(bytes[i]) * keep).rounded())
        bytes[i + 1] = UInt8((color.g * a + Double(bytes[i + 1]) * keep).rounded())
        bytes[i + 2] = UInt8((color.b * a + Double(bytes[i + 2]) * keep).rounded())
        bytes[i + 3] = UInt8((255 * a + Double(bytes[i + 3]) * keep).rounded())
    }

    mutating func ring(around center: (x: Double, y: Double), radius: Double, _ color: PixelColor, alpha: Double) {
        let reach = Int(radius.rounded(.up)) + 1
        let cx = Int(center.x.rounded(.down)), cy = Int(center.y.rounded(.down))
        for y in (cy - reach)...(cy + reach) {
            for x in (cx - reach)...(cx + reach) where abs(hypot(Double(x) + 0.5 - center.x, Double(y) + 0.5 - center.y) - radius) < 0.5 {
                set(x, y, color, alpha: alpha)
            }
        }
    }

    func isEmpty(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, y >= 0, x < columns, y < rows else { return true }
        return bytes[(y * columns + x) * 4 + 3] == 0
    }

    func makeImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: columns * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// A model of cubes: x to the right, y down, z away from you. Each cell holds a colour's index in
/// the creature's palette, or 0 for empty.
struct VoxelModel {
    let width: Int, height: Int, depth: Int
    private(set) var cells: [UInt8]

    init(width: Int, height: Int, depth: Int) {
        self.width = width
        self.height = height
        self.depth = depth
        cells = [UInt8](repeating: 0, count: width * height * depth)
    }

    subscript(x: Int, y: Int, z: Int) -> UInt8 {
        get {
            guard x >= 0, y >= 0, z >= 0, x < width, y < height, z < depth else { return 0 }
            return cells[(z * height + y) * width + x]
        }
        set {
            guard x >= 0, y >= 0, z >= 0, x < width, y < height, z < depth else { return }
            cells[(z * height + y) * width + x] = newValue
        }
    }

    mutating func fill(_ x: Int, _ y: Int, _ z: Int, _ w: Int, _ h: Int, _ d: Int, _ color: UInt8) {
        for k in z..<(z + d) {
            for j in y..<(y + h) {
                for i in x..<(x + w) { self[i, j, k] = color }
            }
        }
    }

    /// Recolours the front-most cell of a column, as a mark drawn on its face.
    mutating func paintFront(_ x: Int, _ y: Int, _ color: UInt8) {
        for z in 0..<depth where self[x, y, z] != 0 {
            self[x, y, z] = color
            return
        }
    }

    /// A flat shape pushed out into depth: each column as deep as `depth` gives (0: empty),
    /// centred on the model's middle plane.
    mutating func extrude(_ depthAt: (Int, Int) -> Int, color: (Int, Int) -> UInt8) {
        for y in 0..<height {
            for x in 0..<width {
                let d = min(depth, depthAt(x, y))
                guard d > 0 else { continue }
                let front = (depth - d) / 2
                fill(x, y, front, 1, 1, d, color(x, y))
            }
        }
    }
}

struct VoxelView {
    /// Degrees: yaw turns its front towards your right (showing its left side), pitch looks down
    /// on it from above, roll spins it clockwise in the picture.
    var yaw = 0.0, pitch = 0.0, roll = 0.0
    /// The model point that stays put as it turns, in cells.
    var pivot: (x: Double, y: Double, z: Double)
    /// Where that point is on the canvas, in pixels from its top left. With no turn, whole numbers
    /// here and in `pivot` put cells exactly on pixels.
    var at: (x: Double, y: Double)

    /// Rows of the model-to-picture turn: roll, then yaw, then pitch.
    fileprivate var matrix: [[Double]] {
        let (r, y, p) = (roll * .pi / 180, yaw * .pi / 180, pitch * .pi / 180)
        let roll = [[cos(r), -sin(r), 0], [sin(r), cos(r), 0], [0, 0, 1.0]]
        let yaw = [[cos(y), 0, -sin(y)], [0, 1, 0], [sin(y), 0, cos(y)]]
        let pitch = [[1, 0, 0], [0, cos(p), -sin(p)], [0, sin(p), cos(p)]]
        return Self.product(pitch, Self.product(yaw, roll))
    }

    private static func product(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        (0..<3).map { i in (0..<3).map { j in (0..<3).reduce(0) { $0 + a[i][$1] * b[$1][j] } } }
    }

    func project(_ x: Double, _ y: Double, _ z: Double) -> (x: Double, y: Double) {
        let m = matrix, v = [x - pivot.x, y - pivot.y, z - pivot.z]
        return (at.x + m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2],
                at.y + m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2])
    }
}

/// The light on a model: its direction as you look (x right, y down, z away) and the ambient share.
struct VoxelLight {
    var from = SIMD3(0.0, -0.45, -1)
    var ambient = 0.6

    /// Light from just above you: a face turned to you stays bright, so a turn shows a darker side.
    static let front = VoxelLight()

    func brightness(_ normal: SIMD3<Double>) -> Double {
        let toward = from / (from * from).sum().squareRoot()
        let lit = ambient + (1 - ambient) * max(0, (normal * toward).sum())
        let full = ambient + (1 - ambient) * max(0, -toward.z)
        // In steps, so a face turning a little doesn't shimmer.
        return (lit / full / 0.04).rounded() * 0.04
    }
}

enum Voxels {
    /// A front face with something just above and in front of it sits in its shadow.
    static let overhang = 0.8

    /// Draws the model onto the image, over what is there. `tone` changes each colour after shading
    /// (a creature fading, greying); `alpha`, how solid it is.
    static func draw(_ model: VoxelModel, palette: [PixelColor], view: VoxelView, into image: inout CreatureImage,
                     light: VoxelLight = .front, tone: ((PixelColor) -> PixelColor)? = nil, alpha: Double = 1) {
        let m = view.matrix
        // From the picture back into the model: the turn's transpose.
        let across = SIMD3(m[0][0], m[0][1], m[0][2]), down = SIMD3(m[1][0], m[1][1], m[1][2])
        let direction = SIMD3(m[2][0], m[2][1], m[2][2])
        let pivot = SIMD3(view.pivot.x, view.pivot.y, view.pivot.z)
        // The brightness of each way a face can point in the model (-x, +x, -y, +y, -z, +z), turned.
        let faces = (0..<6).map { face -> Double in
            var normal = SIMD3(0.0, 0, 0)
            normal[face / 2] = face % 2 == 0 ? -1 : 1
            return light.brightness(SIMD3((0..<3).map { i in (0..<3).reduce(0) { $0 + m[i][$1] * normal[$1] } }))
        }
        for row in 0..<image.rows {
            for column in 0..<image.columns {
                // A hair right of and below the pixel's centre: a centre on a cell's edge then falls
                // the same way at every turn, not by rounding noise (a ragged side, a pixel's jump).
                let origin = pivot + across * (Double(column) + 0.5 + 1e-6 - view.at.x)
                    + down * (Double(row) + 0.5 + 1e-6 - view.at.y)
                guard let (cell, axis) = hit(model, origin, direction) else { continue }
                // The face it came in through points against the ray.
                let facesPlus = direction[axis] < 0
                var factor = faces[axis * 2 + (facesPlus ? 1 : 0)]
                if axis == 2, !facesPlus, model[cell.x, cell.y - 1, cell.z - 1] != 0 { factor *= overhang }
                var color = palette[Int(model[cell.x, cell.y, cell.z]) - 1].scaled(factor)
                if let tone { color = tone(color) }
                image.set(column, row, color, alpha: alpha)
            }
        }
    }

    /// The first filled cell along a ray, and the axis of the face it came in through.
    private static func hit(_ model: VoxelModel, _ o: SIMD3<Double>, _ d: SIMD3<Double>) -> (SIMD3<Int>, Int)? {
        let size = SIMD3(Double(model.width), Double(model.height), Double(model.depth))
        var enter = -Double.infinity, leave = Double.infinity, axis = 2
        for a in 0..<3 {
            if abs(d[a]) < 1e-12 {
                if o[a] < 0 || o[a] >= size[a] { return nil }
                continue
            }
            var t1 = -o[a] / d[a], t2 = (size[a] - o[a]) / d[a]
            if t1 > t2 { swap(&t1, &t2) }
            if t1 > enter { enter = t1; axis = a }
            leave = min(leave, t2)
        }
        guard enter < leave else { return nil }
        var cell = SIMD3<Int>.zero, step = SIMD3<Int>.zero
        var next = SIMD3<Double>.zero, delta = SIMD3<Double>.zero
        for a in 0..<3 {
            cell[a] = Int(min(size[a] - 1, max(0, (o[a] + d[a] * (enter + 1e-7)).rounded(.down))))
            step[a] = d[a] > 0 ? 1 : -1
            if abs(d[a]) < 1e-12 {
                next[a] = .infinity
                delta[a] = .infinity
            } else {
                next[a] = (Double(cell[a] + (d[a] > 0 ? 1 : 0)) - o[a]) / d[a]
                delta[a] = abs(1 / d[a])
            }
        }
        while true {
            if model[cell.x, cell.y, cell.z] != 0 { return (cell, axis) }
            let a = next.x < next.y ? (next.x < next.z ? 0 : 2) : (next.y < next.z ? 1 : 2)
            guard next[a] <= leave else { return nil }
            cell[a] += step[a]
            next[a] += delta[a]
            axis = a
            if cell[a] < 0 || Double(cell[a]) >= size[a] { return nil }
        }
    }
}

/// Timing shared by the creatures: frames at 12 a second, which the display shows evenly (every
/// fifth refresh at 60 Hz, every tenth at 120 Hz).
enum CreatureClock {
    static let step: TimeInterval = 1.0 / 12

    static func frame(_ elapsed: TimeInterval) -> Int { Int((elapsed / step + 1e-6).rounded(.down)) }

    static func seconds(_ frames: Int) -> TimeInterval { Double(frames) * step }

    /// How long a creature waiting on you acts it out before it holds still, and in frames.
    static let askSeconds: TimeInterval = 20
    static let askFrames = 240

    /// A waiting act at a frame (nil: held still): its start once, then its loop, until it holds as
    /// the loop is when the act ends.
    static func act<Pose>(_ start: [Pose], _ loop: [Pose], _ frame: Int?) -> Pose {
        let f = min(frame ?? askFrames - 1, askFrames - 1)
        return f < start.count ? start[f] : loop[(f - start.count) % loop.count]
    }

    /// A reaction at a frame (nil: held still): played once, then held on its last pose.
    static func once<Pose>(_ poses: [Pose], _ frame: Int?) -> Pose { poses[min(frame ?? poses.count - 1, poses.count - 1)] }
}
