import Foundation

/// A lock-protected ring of precomputed RGBA columns — the single source of
/// truth between the DSP producer (audio queue) and the display-link consumer.
///
/// The producer appends finished columns at whatever rate audio arrives (bursty
/// is fine); the consumer composes the visible window on its own clock. Stored
/// row-major (width = `capacity`) so composing a window is a tight copy per row.
/// `producedCount` is a monotonic column index — the consumer chases it.
final class ColumnRing {
    let rows: Int
    let capacity: Int

    private var buf: [UInt8]
    private var produced = 0
    private let lock = NSLock()

    init(rows: Int, capacity: Int) {
        self.rows = rows
        self.capacity = capacity
        self.buf = [UInt8](repeating: 0, count: capacity * rows * 4)
    }

    /// Total columns ever produced (monotonic). The consumer chases this.
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return produced
    }

    /// Append one column: `rows * 4` RGBA bytes, row 0 = top.
    func append(_ column: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        let slot = produced % capacity
        let rowStride = capacity * 4
        column.withUnsafeBufferPointer { src in
            buf.withUnsafeMutableBufferPointer { dst in
                for r in 0..<rows {
                    let s = r * 4
                    let d = r * rowStride + slot * 4
                    dst[d] = src[s]; dst[d + 1] = src[s + 1]
                    dst[d + 2] = src[s + 2]; dst[d + 3] = src[s + 3]
                }
            }
        }
        produced += 1
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        for i in 0..<buf.count { buf[i] = 0 }
        produced = 0
    }

    /// Compose columns `[endColumn - width + 1 ... endColumn]` into `dest`
    /// (row-major, `width × rows × 4`). Columns outside the available range are
    /// left black. Cheap: a few hundred KB of copies, only when a column scrolls
    /// in (~column rate), not per display frame.
    func compose(endColumn: Int, width: Int, into dest: inout [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        let srcRowStride = capacity * 4
        let dstRowStride = width * 4
        let oldest = produced - capacity // smallest still-valid absolute index
        let start = endColumn - width + 1

        dest.withUnsafeMutableBufferPointer { d in
            buf.withUnsafeBufferPointer { s in
                for v in 0..<width {
                    let a = start + v
                    let dCol = v * 4
                    if a >= 0, a >= oldest, a < produced {
                        let slot = a % capacity
                        for r in 0..<rows {
                            let si = r * srcRowStride + slot * 4
                            let di = r * dstRowStride + dCol
                            d[di] = s[si]; d[di + 1] = s[si + 1]
                            d[di + 2] = s[si + 2]; d[di + 3] = s[si + 3]
                        }
                    } else {
                        for r in 0..<rows {
                            let di = r * dstRowStride + dCol
                            d[di] = 0; d[di + 1] = 0; d[di + 2] = 0; d[di + 3] = 0
                        }
                    }
                }
            }
        }
    }
}
