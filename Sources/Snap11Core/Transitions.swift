import CoreGraphics

enum Arrow { case left, right, up, down }

enum SnapState: Equatable {
    case restored
    case maximized
    case arranged(Zone)
}

enum Move: Equatable {
    case snap(Zone)
    /// Same zone kind on the next monitor in the arrow's direction; nothing if there is none.
    case snapOnNextScreen(Zone)
    case restore
    case minimize
    case none
}

/// The Win+Arrow table from the Windows 11 spec. Where Windows is undocumented the rule
/// is "the opposite arrow undoes", and the last monitor in a direction is a wall.
func decide(_ state: SnapState, _ arrow: Arrow) -> Move {
    switch (state, arrow) {
    case (.restored, .up): return .snap(.full)
    case (.restored, .down): return .minimize
    case (.restored, .left), (.maximized, .left): return .snap(.left)
    case (.restored, .right), (.maximized, .right): return .snap(.right)
    case (.maximized, .up): return .none
    case (.maximized, .down): return .restore

    case let (.arranged(z), .up):
        if z.isFullHeight { return .snap(z.topHalf) }
        if z.y > 0.01 { return z.isFullWidth ? .restore : .snap(z.column) }
        return .snap(.full)

    case let (.arranged(z), .down):
        if z.isFullHeight { return .snap(z.bottomHalf) }
        if z.y < 0.01 { return z.isFullWidth ? .restore : .snap(z.column) }
        return .minimize

    case let (.arranged(z), .left): return horizontal(z, towardLeft: true)
    case let (.arranged(z), .right): return horizontal(z, towardLeft: false)
    }
}

private func horizontal(_ z: Zone, towardLeft: Bool) -> Move {
    let atNearEdge = towardLeft ? z.touchesLeft : z.touchesRight
    let atFarEdge = towardLeft ? z.touchesRight : z.touchesLeft
    let isHalfWidth = abs(z.w - 0.5) < 0.01

    if z.isFullWidth {
        return .snap(Zone(x: towardLeft ? 0 : 0.5, y: z.y, w: 0.5, h: z.h))
    }
    if atFarEdge && !atNearEdge {
        if z == .left || z == .right { return .restore }
        if isHalfWidth { return .snap(z.mirrored) }
    }
    if atNearEdge {
        return .snapOnNextScreen(isHalfWidth ? z.mirrored : (towardLeft ? .right : .left))
    }
    return .snap(towardLeft ? .left : .right)
}
