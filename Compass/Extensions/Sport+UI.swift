import CompassData
import SwiftUI

extension Sport {
    var color: Color {
        switch self {
        case .running: .orange
        case .cycling: .blue
        case .swimming: .cyan
        case .hiking: .green
        case .walking: .mint
        case .strength: .red
        case .cardio: .purple
        case .other: .gray
        default: .gray
        }
    }
}
