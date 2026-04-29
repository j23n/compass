import SwiftUI

/// Hero rings component showing Activity, Sleep, Body Battery, and Stress in a 2x2 grid.
struct RingsView: View {
    var activityMinutes: Int
    var activityGoal: Int
    var sleepHours: Double
    var sleepGoal: Double
    var bodyBattery: Int
    var stressLevel: Int

    private var activityProgress: Double {
        guard activityGoal > 0 else { return 0 }
        return Double(activityMinutes) / Double(activityGoal)
    }

    private var sleepProgress: Double {
        guard sleepGoal > 0 else { return 0 }
        return sleepHours / sleepGoal
    }

    private var bodyBatteryProgress: Double {
        Double(bodyBattery) / 100.0
    }

    private var stressProgress: Double {
        Double(stressLevel) / 100.0
    }

    var body: some View {
        Grid(horizontalSpacing: 24, verticalSpacing: 20) {
            GridRow {
                RingView(
                    progress: activityProgress,
                    lineWidth: 10,
                    color: .green,
                    icon: "figure.walk",
                    label: "Activity",
                    valueText: "\(activityMinutes) min"
                )

                RingView(
                    progress: sleepProgress,
                    lineWidth: 10,
                    color: .purple,
                    icon: "bed.double.fill",
                    label: "Sleep",
                    valueText: formatSleepHours(sleepHours)
                )
            }

            GridRow {
                RingView(
                    progress: bodyBatteryProgress,
                    lineWidth: 10,
                    color: .blue,
                    icon: "battery.75percent",
                    label: "Body Battery",
                    valueText: "\(bodyBattery)"
                )

                RingView(
                    progress: stressProgress,
                    lineWidth: 10,
                    color: .orange,
                    icon: "brain.head.profile",
                    label: "Stress",
                    valueText: "\(stressLevel)"
                )
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 8)
    }

    private func formatSleepHours(_ hours: Double) -> String {
        let h = Int(hours)
        let m = Int((hours - Double(h)) * 60)
        if m == 0 {
            return "\(h) hr"
        }
        return "\(h)h \(m)m"
    }
}

#Preview {
    RingsView(
        activityMinutes: 45,
        activityGoal: 60,
        sleepHours: 7.5,
        sleepGoal: 8,
        bodyBattery: 72,
        stressLevel: 35
    )
    .padding()
}
