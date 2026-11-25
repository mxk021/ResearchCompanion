import Foundation
import AppKit
import SwiftUI

// MARK: - 状态颜色契约

struct MoodColorConfig {
    let mood: String
    let label: String
    let defaultHex: UInt32
}

let moodColorConfigs: [MoodColorConfig] = [
    MoodColorConfig(mood: "idle", label: "空闲", defaultHex: 0x60a5fa),
    MoodColorConfig(mood: "waiting", label: "正在思考中", defaultHex: 0x34d399),
    MoodColorConfig(mood: "jumping", label: "工具调用", defaultHex: 0xa855f7),
    MoodColorConfig(mood: "authorizing", label: "等待你的授权", defaultHex: 0xfacc15),
    MoodColorConfig(mood: "questioning", label: "做出你的抉择", defaultHex: 0xec4899),
    MoodColorConfig(mood: "done", label: "搞定啦", defaultHex: 0x22d3ee),
    MoodColorConfig(mood: "failed", label: "出错了", defaultHex: 0xf87171),
    MoodColorConfig(mood: "stopped", label: "已停止", defaultHex: 0x000000),
]

let disconnectedHex: UInt32 = 0x9ca3af

/// Shared rendering rule for the stopped status ball. The ball is pure black,
/// so dark configured eyes would disappear; the preview, export and live pet
/// must all use the same substitute.
enum StatusBallAppearance {
    static func eyeColor(for mood: String, configured: Color) -> Color {
        mood == "stopped" ? .white : configured
    }

    static func showsStoppedRing(for mood: String) -> Bool {
        mood == "stopped"
    }
}

// MARK: - 桌宠类型与通用设置

enum FloatingPetSkin: RawRepresentable, CaseIterable, Identifiable, Hashable {
    case bookmark
    case jingyuniang
    case jingyuniangQ
    case xiaoyu
    case xinzhizhu
    case classic
    case custom(String)

    static let publicDistribution = Bundle.main.object(forInfoDictionaryKey: "ResearchCompanionPublicDistribution") as? Bool == true
    static var defaultSkin: Self { publicDistribution ? .bookmark : .jingyuniang }
    static var allCases: [Self] {
        publicDistribution ? [.bookmark, .classic] : [.jingyuniang, .jingyuniangQ, .xiaoyu, .xinzhizhu, .classic]
    }

    static func resolved(saved: Self?, imported: [Self], publicBuild: Bool) -> Self {
        let fallback: Self = publicBuild ? .bookmark : .jingyuniang
        guard let saved else { return fallback }
        if case .custom = saved { return imported.contains(saved) ? saved : fallback }
        return publicBuild && saved != .classic ? .bookmark : saved
    }

    init?(rawValue: String) {
        switch rawValue {
        case "bookmark": self = .bookmark
        case "jingyuniang": self = .jingyuniang
        case "jingyuniangQ": self = .jingyuniangQ
        case "xiaoyu": self = .xiaoyu
        case "xinzhizhu": self = .xinzhizhu
        case "classic": self = .classic
        default:
            guard rawValue.hasPrefix("custom:"),
                  let id = UUID(uuidString: String(rawValue.dropFirst(7))) else { return nil }
            self = .custom(id.uuidString.lowercased())
        }
    }

    var rawValue: String {
        switch self {
        case .bookmark: return "bookmark"
        case .jingyuniang: return "jingyuniang"
        case .jingyuniangQ: return "jingyuniangQ"
        case .xiaoyu: return "xiaoyu"
        case .xinzhizhu: return "xinzhizhu"
        case .classic: return "classic"
        case .custom(let id): return "custom:\(id)"
        }
    }

    var isSprite: Bool { self != .classic }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bookmark: return "书签"
        case .classic: return "心情球"
        case .xiaoyu: return "小雨"
        case .xinzhizhu: return "新之助"
        case .jingyuniang: return "鲸鱼娘"
        case .jingyuniangQ: return "鲸鱼娘Q版"
        case .custom: return "自定义宠物"
        }
    }
}

enum EyeColor: String, CaseIterable, Identifiable {
    case white
    case black

    var id: String { rawValue }

    var label: String {
        switch self {
        case .white: return "白色"
        case .black: return "黑色"
        }
    }

    var color: Color {
        switch self {
        case .white: return .white
        case .black: return .black
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

/// Shared pet settings, persisted under the `dsh-pet.*` namespace.
@MainActor
final class PetSettings: ObservableObject {
    static let shared = PetSettings()

    private let defaults: UserDefaults

    private enum Key {
        static let skin = "dsh-pet.skin"
        static let ballSize = "dsh-pet.ballSize"
        static let breathingSpeed = "dsh-pet.breathingSpeed"
        static let rememberPosition = "dsh-pet.rememberPosition"
        static let showEyes = "dsh-pet.showEyes"
        static let eyeColor = "dsh-pet.eyeColor"
        static let showStatusBubble = "dsh-pet.showStatusBubble"
        static let glowEnabled = "dsh-pet.glowEnabled"
        static let lockPosition = "dsh-pet.lockPosition"
        static let isPetVisible = "dsh-pet.isPetVisible"
        static let moodColorPrefix = "dsh-pet.moodColor."
    }

    @Published var skin: FloatingPetSkin {
        didSet { defaults.set(skin.rawValue, forKey: Key.skin) }
    }

    @Published var ballSize: CGFloat {
        didSet { defaults.set(Double(ballSize), forKey: Key.ballSize) }
    }

    @Published var breathingSpeed: Double {
        didSet { defaults.set(breathingSpeed, forKey: Key.breathingSpeed) }
    }

    @Published var showStatusBubble: Bool {
        didSet { defaults.set(showStatusBubble, forKey: Key.showStatusBubble) }
    }

    @Published var glowEnabled: Bool {
        didSet { defaults.set(glowEnabled, forKey: Key.glowEnabled) }
    }

    @Published var isPetVisible: Bool {
        didSet { defaults.set(isPetVisible, forKey: Key.isPetVisible) }
    }

    @Published var lockPosition: Bool {
        didSet { defaults.set(lockPosition, forKey: Key.lockPosition) }
    }

    @Published var showEyes: Bool {
        didSet { defaults.set(showEyes, forKey: Key.showEyes) }
    }

    @Published var eyeColor: EyeColor {
        didSet { defaults.set(eyeColor.rawValue, forKey: Key.eyeColor) }
    }

    @Published var rememberPosition: Bool {
        didSet { defaults.set(rememberPosition, forKey: Key.rememberPosition) }
    }

    @Published private(set) var moodColors: [String: Color] = [:]

    @Published var disconnectedColor: Color {
        didSet { writeColor(disconnectedColor, key: Key.moodColorPrefix + "disconnected") }
    }

    init(defaults: UserDefaults = .standard, petLibrary: CustomPetLibrary? = nil) {
        self.defaults = defaults
        let petLibrary = petLibrary ?? .shared
        let clamp = { (value: Double, lower: Double, upper: Double) in min(max(value, lower), upper) }

        let savedSkin = defaults.string(forKey: Key.skin)
        let initialSkin = FloatingPetSkin.resolved(saved: savedSkin.flatMap(FloatingPetSkin.init(rawValue:)),
            imported: petLibrary.pets.map(\.skin), publicBuild: FloatingPetSkin.publicDistribution)
        skin = initialSkin
        // A public launch on the maintainer's Mac displays its bundled alternative
        // without overwriting the original private skin selection on disk.
        if savedSkin != initialSkin.rawValue && !(FloatingPetSkin.publicDistribution && savedSkin != nil) {
            defaults.set(initialSkin.rawValue, forKey: Key.skin)
        }
        ballSize = CGFloat(clamp(Self.number(defaults, for: Key.ballSize) ?? 120, 60, 200))
        breathingSpeed = clamp(Self.number(defaults, for: Key.breathingSpeed) ?? 2, 0.5, 5)
        rememberPosition = Self.bool(defaults, for: Key.rememberPosition) ?? true
        showEyes = Self.bool(defaults, for: Key.showEyes) ?? true
        eyeColor = EyeColor(rawValue: Self.string(defaults, for: Key.eyeColor) ?? "") ?? .black
        showStatusBubble = Self.bool(defaults, for: Key.showStatusBubble) ?? true
        glowEnabled = Self.bool(defaults, for: Key.glowEnabled) ?? true
        lockPosition = Self.bool(defaults, for: Key.lockPosition) ?? false
        isPetVisible = Self.bool(defaults, for: Key.isPetVisible) ?? true
        disconnectedColor = Color(hex: Self.hex(defaults, for: Key.moodColorPrefix + "disconnected") ?? disconnectedHex)

        var colors: [String: Color] = [:]
        for config in moodColorConfigs {
            let key = Key.moodColorPrefix + config.mood
            colors[config.mood] = Color(hex: Self.hex(defaults, for: key) ?? config.defaultHex)
        }
        moodColors = colors
    }

    func setMoodColor(_ mood: String, _ color: Color) {
        moodColors[mood] = color
        writeColor(color, key: Key.moodColorPrefix + mood)
    }

    func resetMoodColors() {
        var colors: [String: Color] = [:]
        for config in moodColorConfigs {
            colors[config.mood] = Color(hex: config.defaultHex)
            defaults.removeObject(forKey: Key.moodColorPrefix + config.mood)
        }
        moodColors = colors
        disconnectedColor = Color(hex: disconnectedHex)
        defaults.removeObject(forKey: Key.moodColorPrefix + "disconnected")
    }

    private static func number(_ defaults: UserDefaults, for key: String) -> Double? {
        if let number = defaults.object(forKey: key) as? NSNumber { return number.doubleValue }
        if let string = defaults.object(forKey: key) as? String { return Double(string) }
        return nil
    }

    private static func string(_ defaults: UserDefaults, for key: String) -> String? {
        if let string = defaults.object(forKey: key) as? String { return string }
        if let number = defaults.object(forKey: key) as? NSNumber { return number.stringValue }
        return nil
    }

    private static func bool(_ defaults: UserDefaults, for key: String) -> Bool? {
        defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key)
    }

    private static func hex(_ defaults: UserDefaults, for key: String) -> UInt32? {
        if let string = defaults.object(forKey: key) as? String {
            return UInt32(string, radix: 16)
        }
        if let number = defaults.object(forKey: key) as? NSNumber {
            return number.uint32Value
        }
        return nil
    }

    private func writeColor(_ color: Color, key: String) {
        defaults.set(String(format: "%06X", colorToHex(color)), forKey: key)
    }
}

extension Notification.Name {
    static let dshPetResetPosition = Notification.Name("dshPetResetPosition")
}

func colorToHex(_ color: Color) -> UInt32 {
    let resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
    let r = Int((resolved.redComponent * 255).rounded())
    let g = Int((resolved.greenComponent * 255).rounded())
    let b = Int((resolved.blueComponent * 255).rounded())
    return UInt32(r << 16 | g << 8 | b)
}
