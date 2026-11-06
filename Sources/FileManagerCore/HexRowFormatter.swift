import Foundation

/// Always 16 byte slots, including on the last partial row, so ASCII stays aligned.
public enum HexRowFormatter {
    public static func columns(forByte index: Int) -> (hex: Range<Int>, ascii: Range<Int>) {
        precondition((0..<16).contains(index))
        let hexStart = 18 + index * 3 + (index >= 8 ? 1 : 0)
        return (hexStart..<(hexStart + 2), (68 + index)..<(69 + index))
    }
    public static func format(offset: Int64, bytes: [UInt8]) -> String {
        let values = Array(bytes.prefix(16))
        let slots = (0..<16).map { index in
            index < values.count ? String(format: "%02X", values[index]) : "  "
        }
        let hex = slots[..<8].joined(separator: " ") + "  " + slots[8...].joined(separator: " ")
        let ascii = values.map { (32...126).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
        return String(format: "%016llX: ", offset) + hex + "  " + ascii
    }
}
