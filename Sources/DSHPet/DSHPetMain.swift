import AppKit
import CoreFoundation

// 纯菜单栏应用入口。
//
// 不用 SwiftUI App 生命周期：MenuBarExtra 会把菜单栏 label 强制渲染成单色模板图片，
// mood 颜色会丢失（看起来就是黑点/白点）。改由 AppDelegate 用 AppKit 的
// NSStatusItem 自绘非模板彩色图标（见 AppDelegate.setupStatusItem）。
@main
enum DSHPetMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.count == 3,
           ["--check-bridge", "--verify-live-session"].contains(CommandLine.arguments[1]) {
            Task { @MainActor in
                let code = CommandLine.arguments[1] == "--verify-live-session"
                    ? await ResearchLiveSessionCheck.run(manifestPath: CommandLine.arguments[2])
                    : await ResearchBridgeSelfCheck.run(manifestPath: CommandLine.arguments[2])
                exit(code)
            }
            CFRunLoopRun()
            return
        }
        let app = NSApplication.shared
        ResearchLaunchLog.write("main-entered")
        let delegate = AppDelegate()
        app.delegate = delegate
        // NSApplication keeps a weak delegate. Keep it alive across the event
        // loop even when Release ARC ends the local's lifetime after assignment.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
