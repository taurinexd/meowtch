/// Pure math for the pixel state indicators: the running dual-chase
/// spinner and the compacting squash column. Views sample these with
/// PixelClock ticks; tests pin the cycles.
public enum IndicatorFrames {
    /// Perimeter of a 3×3 grid, clockwise from the top-left corner.
    public static let ring: [(x: Int, y: Int)] = [
        (0, 0), (1, 0), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2), (0, 1),
    ]

    /// Two opposite heads chasing on the ring; each cell fades with its
    /// distance from the nearest head.
    public static func dualChaseAlpha(index: Int, tick: Int) -> Double {
        let d1 = (((index - tick) % 8) + 8) % 8
        let d2 = (((index - tick - 4) % 8) + 8) % 8
        return max(0, 1 - Double(min(d1, d2)) * 0.3)
    }

    /// Lit-row cycle of the compacting column (squash and re-expand).
    public static let squashHeights = [4, 3, 2, 1, 2, 3]

    public static func squashRowCount(tick: Int) -> Int {
        let n = squashHeights.count
        return squashHeights[((tick % n) + n) % n]
    }
}
