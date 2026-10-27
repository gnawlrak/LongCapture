import AppKit
import Carbon

struct HotKeyShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    static let defaultShortcut = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey))

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

final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let shortcut: HotKeyShortcut
    private let callback: () -> Void
    private static let signature: OSType = 0x4C434150 // LCAP

    init(shortcut: HotKeyShortcut, callback: @escaping () -> Void) {
        self.shortcut = shortcut
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
            guard status == noErr, identifier.signature == HotKey.signature, identifier.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().callback()
            return noErr
        }, 1, &spec, userData, &handler)
        guard installed == noErr else { throw HotKeyError.registration(installed) }
        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, identifier,
                                        GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else { unregister(); throw HotKeyError.registration(status) }
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
