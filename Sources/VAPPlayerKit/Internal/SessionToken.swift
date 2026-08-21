import Foundation
import CoreGraphics

enum SessionToken: Equatable {
    case value(UInt64)

    static func make() -> SessionToken {
        .value(UInt64.random(in: 1...UInt64.max))
    }
}
