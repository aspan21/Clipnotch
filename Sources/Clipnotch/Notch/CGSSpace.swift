//
//  CGSSpace.swift
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
//  Original source: https://github.com/avaidyam/Parrot
//
//  Puts a window into a private CoreGraphics space pinned above every other
//  space, which is the only way to keep a panel visible over fullscreen apps.
//

import AppKit

final class CGSSpace {
    private let identifier: CGSSpaceID

    var windows: Set<NSWindow> = [] {
        didSet {
            let removed = oldValue.subtracting(windows)
            let added = windows.subtracting(oldValue)
            if !removed.isEmpty {
                CGSRemoveWindowsFromSpaces(_CGSDefaultConnection(),
                                           removed.map { $0.windowNumber } as NSArray,
                                           [identifier])
            }
            if !added.isEmpty {
                CGSAddWindowsToSpaces(_CGSDefaultConnection(),
                                      added.map { $0.windowNumber } as NSArray,
                                      [identifier])
            }
        }
    }

    init(level: Int = 0) {
        // Must be 1; anything else makes Finder redraw desktop icons into the space.
        let flag = 0x1
        identifier = CGSSpaceCreate(_CGSDefaultConnection(), flag, nil)
        CGSSpaceSetAbsoluteLevel(_CGSDefaultConnection(), identifier, level)
        CGSShowSpaces(_CGSDefaultConnection(), [identifier])
    }

    deinit {
        CGSHideSpaces(_CGSDefaultConnection(), [identifier])
        CGSSpaceDestroy(_CGSDefaultConnection(), identifier)
    }
}

private typealias CGSConnectionID = UInt
private typealias CGSSpaceID = UInt64

@_silgen_name("_CGSDefaultConnection")
private func _CGSDefaultConnection() -> CGSConnectionID

@_silgen_name("CGSSpaceCreate")
private func CGSSpaceCreate(_ cid: CGSConnectionID, _ unknown: Int, _ options: NSDictionary?) -> CGSSpaceID

@_silgen_name("CGSSpaceDestroy")
private func CGSSpaceDestroy(_ cid: CGSConnectionID, _ space: CGSSpaceID)

@_silgen_name("CGSSpaceSetAbsoluteLevel")
private func CGSSpaceSetAbsoluteLevel(_ cid: CGSConnectionID, _ space: CGSSpaceID, _ level: Int)

@_silgen_name("CGSShowSpaces")
private func CGSShowSpaces(_ cid: CGSConnectionID, _ spaces: NSArray)

@_silgen_name("CGSHideSpaces")
private func CGSHideSpaces(_ cid: CGSConnectionID, _ spaces: NSArray)

@_silgen_name("CGSAddWindowsToSpaces")
private func CGSAddWindowsToSpaces(_ cid: CGSConnectionID, _ windows: NSArray, _ spaces: NSArray)

@_silgen_name("CGSRemoveWindowsFromSpaces")
private func CGSRemoveWindowsFromSpaces(_ cid: CGSConnectionID, _ windows: NSArray, _ spaces: NSArray)

enum NotchSpace {
    /// Created lazily so a failure in the private API cannot break app launch.
    static let shared: CGSSpace? = {
        guard Settings.shared.showOverFullscreen else { return nil }
        return CGSSpace(level: Int(Int32.max))
    }()
}
