import AppKit
import Carbon

struct HotKeyShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    static let defaultShortcut = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey))
    static let defaultQuickShortcut = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey | shiftKey))

    var displayName: String {
        let flags: [(UInt32, String)] = [(UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"),
                                         (UInt32(shiftKey), "⇧"), (UInt32(cmdKey), "⌘")]
        let prefix = flags.filter { modifiers & $0.0 != 0 }.map(\.1).joined()
        let keys: [UInt32: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",
            11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",
            23:"5",24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",
            35:"P",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",
            49:"空格",50:"`",96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",103:"F11",
            109:"F10",111:"F12",118:"F4",120:"F2",122:"F1",123:"←",124:"→",125:"↓",126:"↑"]
        return prefix + (keys[keyCode] ?? "键 \(keyCode)")
    }
}

enum CaptureShortcutAction: UInt32, CaseIterable {
    case confirmation = 1, quick = 2
    var title: String { self == .confirmation ? "调整模式" : "快速模式" }
    var storageKey: String { self == .confirmation ? "LongCapture.shortcut" : "LongCapture.quickShortcut" }
    var startMode: SelectionStartMode { self == .confirmation ? .confirmation : .onRelease }

    func intent(state: SessionCoordinator.State, hasResult: Bool,
                selectionMode: SelectionStartMode?) -> CaptureShortcutIntent {
        if hasResult { return .openResult }
        switch state {
        case .idle: return .select(startMode)
        case .capturing: return .complete
        case .selecting:
            return self == .confirmation && selectionMode == .confirmation ? .confirm : .ignore
        default: return .ignore
        }
    }
}

enum CaptureShortcutIntent: Equatable {
    case select(SelectionStartMode), confirm, complete, openResult, ignore
}

protocol HotKeyRegistration: AnyObject {
    func register() throws
    func unregister()
}

@MainActor
final class CaptureShortcuts {
    typealias Factory = (CaptureShortcutAction, HotKeyShortcut, @escaping () -> Void) -> any HotKeyRegistration
    private let defaults: UserDefaults
    private let factory: Factory
    private let onAction: (CaptureShortcutAction) -> Void
    private var values: [CaptureShortcutAction: HotKeyShortcut] = [:]
    private var registrations: [CaptureShortcutAction: any HotKeyRegistration] = [:]
    private var generation: UInt = 0
    private var validationMessages: [CaptureShortcutAction: String] = [:]
    private(set) var messages: [CaptureShortcutAction: String] = [:]
    private(set) var isSuspended = false

    init(defaults: UserDefaults = .standard,
         factory: @escaping Factory = { action, shortcut, callback in
             HotKey(shortcut: shortcut, identifier: action.rawValue, callback: callback)
         }, onAction: @escaping (CaptureShortcutAction) -> Void) {
        self.defaults = defaults
        self.factory = factory
        self.onAction = onAction
        for action in CaptureShortcutAction.allCases {
            let fallback: HotKeyShortcut = action == .confirmation ? .defaultShortcut : .defaultQuickShortcut
            values[action] = defaults.data(forKey: action.storageKey)
                .flatMap { try? JSONDecoder().decode(HotKeyShortcut.self, from: $0) } ?? fallback
        }
        // A pre-existing custom shortcut takes precedence over the newly introduced default.
        if values[.quick] == values[.confirmation] { values[.quick] = nil }
        refreshMissingShortcutMessage()
    }

    func shortcut(for action: CaptureShortcutAction) -> HotKeyShortcut? { values[action] }

    @discardableResult
    func change(_ shortcut: HotKeyShortcut, for action: CaptureShortcutAction) -> Bool {
        if CaptureShortcutAction.allCases.contains(where: { $0 != action && values[$0] == shortcut }) {
            validationMessages[action] = "两个截图快捷键不能相同；原快捷键保持不变。"
            messages[action] = validationMessages[action]
            return false
        }
        values[action] = shortcut
        if let data = try? JSONEncoder().encode(shortcut) { defaults.set(data, forKey: action.storageKey) }
        messages[action] = nil
        validationMessages[action] = nil
        if !isSuspended { register() }
        return true
    }

    func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        isSuspended = suspended
        if suspended { unregister() }
        else { register() }
    }

    func register() {
        unregister()
        guard !isSuspended else { return }
        messages = validationMessages
        refreshMissingShortcutMessage()
        let generation = self.generation
        for action in CaptureShortcutAction.allCases {
            guard let shortcut = values[action] else { continue }
            let key = factory(action, shortcut) { [weak self] in
                Task { @MainActor in
                    guard let self, self.generation == generation, !self.isSuspended,
                          self.registrations[action] != nil else { return }
                    self.onAction(action)
                }
            }
            do { try key.register(); registrations[action] = key }
            catch {
                key.unregister()
                messages[action] = [validationMessages[action], error.localizedDescription].compactMap { $0 }.joined(separator: "\n")
            }
        }
    }

    private func unregister() {
        generation &+= 1
        for key in registrations.values { key.unregister() }
        registrations = [:]
    }

    private func refreshMissingShortcutMessage() {
        if values[.quick] == nil, messages[.quick] == nil {
            messages[.quick] = "快速模式默认组合已用作调整模式，请为快速模式设置不同快捷键。菜单入口仍可使用。"
        }
    }
}

final class HotKey: HotKeyRegistration {
    private var hotKeyRef: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let shortcut: HotKeyShortcut
    private let callback: () -> Void
    static let signature: OSType = 0x4C434150 // LCAP
    private let identifier: UInt32

    init(shortcut: HotKeyShortcut, identifier: UInt32 = 1, callback: @escaping () -> Void) {
        self.shortcut = shortcut
        self.identifier = identifier
        self.callback = callback
    }

    func register() throws {
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr else { return OSStatus(eventNotHandledErr) }
            return Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().handle(identifier)
        }, 1, &spec, userData, &handler)
        guard installed == noErr else { throw HotKeyError.registration(installed) }
        let identifier = EventHotKeyID(signature: Self.signature, id: self.identifier)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, identifier,
                                        GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else { unregister(); throw HotKeyError.registration(status) }
    }

    func handle(_ eventID: EventHotKeyID) -> OSStatus {
        guard eventID.signature == Self.signature, eventID.id == identifier else { return OSStatus(eventNotHandledErr) }
        callback()
        return noErr
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }

    deinit { unregister() }
}

enum HotKeyError: LocalizedError {
    case registration(OSStatus)
    var errorDescription: String? {
        switch self {
        case .registration(let status):
            return "全局快捷键无法注册（\(status)），可能已被其他应用占用。菜单栏入口仍可使用，请在设置中更换快捷键。"
        }
    }
}
