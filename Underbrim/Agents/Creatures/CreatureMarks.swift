//
//  CreatureMarks.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The cartoon marks beside a creature, drawn flat in its square pixels; each has its
//  own shape, so none leans on colour alone.
//

import Foundation

enum CreatureMark: Equatable {
    case question, exclamation
    /// Up to three dots, as many as have appeared, each where it stays.
    case dots(Int)
    case sweat
    /// A twinkle growing: 0 a dot, 1 a small cross, 2 a bigger one.
    case twinkle(Int)
    case star, tick, stop

    /// Its pixels, row by row from the top: "#" filled.
    var rows: [String] {
        switch self {
        case .question: [".##.", "#..#", "..#.", "....", "..#."]
        case .exclamation: ["##", "##", "##", "..", "##"]
        case .dots(let count): [String((0..<5).map { $0 % 2 == 0 && $0 / 2 < count ? "#" : "." })]
        case .sweat: [".#", "##", "##"]
        case .twinkle(0): ["#"]
        case .twinkle(1): [".#.", "###", ".#."]
        case .twinkle: ["..#..", "..#..", "##.##", "..#..", "..#.."]
        case .star: [".#.", "#.#", ".#."]
        case .tick: ["....#", "...##", "#.##.", "###..", ".#..."]
        case .stop: ["####", "####", "####", "####"]
        }
    }

    var color: PixelColor {
        switch self {
        case .question, .exclamation, .dots, .stop: PixelColor(242, 245, 255)
        case .star: PixelColor(255, 246, 204)
        case .tick: PixelColor(104, 222, 128)
        case .sweat: PixelColor(130, 196, 255)
        case .twinkle: PixelColor(255, 240, 170)
        }
    }

    var width: Int { rows.map(\.count).max() ?? 0 }
    var height: Int { rows.count }
}

extension CreatureImage {
    /// Draws a mark with its bottom row's middle at a point, in pixels from the top left.
    mutating func draw(_ mark: CreatureMark, bottomCenter point: (x: Double, y: Double), alpha: Double = 1) {
        let left = Int((point.x - Double(mark.width) / 2).rounded()), bottom = Int(point.y.rounded(.down))
        for (row, line) in mark.rows.enumerated() {
            for (column, character) in line.enumerated() where character == "#" {
                set(left + column, bottom - (mark.height - 1) + row, mark.color, alpha: alpha)
            }
        }
    }
}
