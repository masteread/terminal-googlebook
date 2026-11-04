import Foundation

/// Traduce acciones del agente a lo que entienden QMP (`input-send-event`) y el helper del guest.
public enum GuestInput {
    private static let named: [String: String] = [
        "enter": "ret", "return": "ret", "esc": "esc", "escape": "esc", "tab": "tab", "space": "spc",
        "backspace": "backspace", "delete": "delete", "del": "delete", "up": "up", "down": "down", "left": "left", "right": "right",
        "home": "home", "end": "end", "pageup": "pgup", "pagedown": "pgdn",
        "ctrl": "ctrl", "control": "ctrl", "alt": "alt", "option": "alt", "shift": "shift", "meta": "meta_l", "cmd": "meta_l", "super": "meta_l"
    ]
    private static let plain: [Character: String] = [
        " ": "spc", "\n": "ret", "\t": "tab", "-": "minus", "=": "equal", "[": "bracket_left", "]": "bracket_right", "\\": "backslash",
        ";": "semicolon", "'": "apostrophe", ",": "comma", ".": "dot", "/": "slash", "`": "grave_accent"
    ]
    private static let shifted: [Character: String] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "minus", "+": "equal", "{": "bracket_left", "}": "bracket_right", "|": "backslash",
        ":": "semicolon", "\"": "apostrophe", "<": "comma", ">": "dot", "?": "slash", "~": "grave_accent"
    ]

    /// Las qcodes que hay que pulsar a la vez para producir un carácter ASCII, o nil si no hay tecla directa.
    public static func keys(for character: Character) -> [String]? {
        guard character.isASCII else { return nil }
        if character.isLowercase || character.isNumber { return [String(character)] }
        if character.isUppercase { return ["shift", character.lowercased()] }
        if let code = plain[character] { return [code] }
        if let code = shifted[character] { return ["shift", code] }
        return nil
    }

    /// `ctrl+t`, `enter`, `shift+tab`, `f5`.
    public static func chord(_ text: String) throws -> [String] {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { throw Failure("Empty key") }
        var codes: [String] = []
        for part in parts {
            if let code = named[part] { codes.append(code) }
            else if part.count <= 3, part.hasPrefix("f"), let n = Int(part.dropFirst()), (1...12).contains(n) { codes.append(part) }
            else if part.count == 1, let first = part.first, let keys = keys(for: first) { codes += keys }
            else { throw Failure("Unknown key: \(part)") }
        }
        return codes
    }

    public enum Run: Equatable {
        case keys([[String]])
        case paste(String)
    }

    /// Lo que tiene tecla directa va por QMP. El resto de UTF-8 no existe en un teclado
    /// virtual, así que se pega dentro del guest; el clipboard del host no interviene.
    public static func runs(_ text: String) -> [Run] {
        var result: [Run] = []
        for character in text {
            if let codes = keys(for: character) {
                if case .keys(let existing)? = result.last { result[result.count - 1] = .keys(existing + [codes]) }
                else { result.append(.keys([codes])) }
            } else {
                if case .paste(let existing)? = result.last { result[result.count - 1] = .paste(existing + String(character)) }
                else { result.append(.paste(String(character))) }
            }
        }
        return result
    }

    /// Solo http y https, y sin nada que el omnibox interprete como otra tecla.
    public static func validatedURL(_ text: String) throws -> String {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil,
              text.allSatisfy({ $0.isASCII && !$0.isWhitespace && !$0.isNewline }) else {
            throw Failure("open_url needs an http or https URL without spaces")
        }
        return text
    }
}
