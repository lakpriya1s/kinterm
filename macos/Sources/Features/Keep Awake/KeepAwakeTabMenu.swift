import SwiftUI

/// "Keep Mac Awake Until This Tab Finishes" in an agent tab's right-click
/// menu, or "Stop Keeping Mac Awake" when it already does.
struct KeepAwakeTabMenu: View {
    let controller: BaseTerminalController

    @ObservedObject private var awake = KeepAwake.shared

    /// The terminal in the tab that's busy: its agent, or a command.
    private var surface: Ghostty.SurfaceView? {
        let surfaces = controller.allSurfaces
        return surfaces.first { awake.hold(for: $0) != nil }
            ?? surfaces.first { $0.programStatus?.state == .working }
            ?? surfaces.first { KeepAwake.isBusy($0) }
    }

    var body: some View {
        if let surface {
            Divider()
            if awake.hold(for: surface) != nil {
                Button("Stop Keeping Mac Awake for This Tab") { awake.release(surface) }
            } else {
                Button("Keep Mac Awake Until This Tab Finishes") { awake.hold(surface) }
            }
        }
    }
}

/// The command palette's Keep Mac Awake commands. `surface` is the terminal
/// the palette is over.
@MainActor
enum KeepAwakeCommands {
    static func options(for surface: Ghostty.SurfaceView) -> [CommandOption] {
        let awake = KeepAwake.shared
        let icon = "cup.and.saucer"
        var options: [CommandOption] = []

        options.append(CommandOption(
            title: "Keep Awake: While Agents Work",
            description: "Keep the Mac awake while an agent in any tab works, then for a few minutes after.",
            leadingIcon: icon,
            badge: awake.whileAgentsWork ? "On" : nil
        ) { awake.whileAgentsWork.toggle() })

        for minutes in KeepAwake.durations {
            options.append(CommandOption(
                title: "Keep Awake: For \(KeepAwake.duration(minutes: minutes))",
                description: "Keep the Mac awake for \(KeepAwake.duration(minutes: minutes)), then let it sleep.",
                leadingIcon: icon
            ) { awake.keepAwake(minutes: minutes) })
        }

        options.append(CommandOption(
            title: "Keep Awake: Until I Turn It Off",
            description: "Keep the Mac awake until you turn it off.",
            leadingIcon: icon,
            badge: awake.manualUntil == .distantFuture ? "On" : nil
        ) { awake.keepAwake(minutes: nil) })

        if awake.hold(for: surface) != nil {
            options.append(CommandOption(
                title: "Keep Awake: Stop Waiting for This Terminal",
                description: "Stop keeping the Mac awake for what runs here.",
                leadingIcon: icon
            ) { awake.release(surface) })
        } else if KeepAwake.isBusy(surface) {
            options.append(CommandOption(
                title: "Keep Awake: Until This Finishes",
                description: "Keep the Mac awake until \(KeepAwake.describe(surface)) finishes.",
                leadingIcon: icon
            ) { awake.hold(surface) })
        }

        options.append(CommandOption(
            title: "Keep Awake: Keep Display On",
            description: "While keeping the Mac awake, keep the screen on too.",
            leadingIcon: "display",
            badge: awake.keepDisplayOn ? "On" : nil
        ) { awake.keepDisplayOn.toggle() })

        if awake.manualUntil != nil || !awake.holds.isEmpty {
            options.append(CommandOption(
                title: "Keep Awake: Turn Off",
                description: "Stop the timer and stop waiting for terminals. While Agents Work stays as it is.",
                leadingIcon: "cup.and.saucer.fill",
                emphasis: false
            ) { awake.turnOff() })
        }
        return options
    }
}
