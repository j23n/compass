import CompassData
import SwiftUI

extension Sport {
    var color: Color {
        switch self {
        case .running:      .orange
        case .cycling:      .blue
        case .mtb:          .green
        case .swimming:     .cyan
        case .hiking:       .green
        case .walking:      .mint
        case .strength:     .red
        case .yoga:         .pink
        case .cardio:       .purple
        case .rowing:       .teal
        case .kayaking:     .cyan
        case .skiing:       .indigo
        case .snowboarding: .purple
        case .sup:          .mint
        case .climbing:     .brown
        case .boating:      .blue
        case .other:        .gray
        }
    }
}
