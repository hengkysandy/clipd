import os

/// Diagnostic logging for the shell.
///
/// Rejected: NSLog. Measured on macOS 26: NSLog redacts its arguments as
/// <private> in unified logging even with %{public} specifiers, which makes
/// every diagnostic unreadable and indistinguishable from "nothing happened".
/// os.Logger honours the privacy attribute properly.
///
/// HARD RULE: no clipboard value is ever passed to this. Counts, byte sizes,
/// bundle identifiers and refusal reasons only. During probing a diagnostic
/// printed a 40 character text preview and wrote a real password to a file.
enum Diag {
    static let capture = Logger(subsystem: "com.hengkysandy.clipd.mac",
                                category: "capture")
    static let paste = Logger(subsystem: "com.hengkysandy.clipd.mac",
                              category: "paste")
    static let panel = Logger(subsystem: "com.hengkysandy.clipd.mac",
                              category: "panel")
    static let sync = Logger(subsystem: "com.hengkysandy.clipd.mac",
                             category: "sync")
}
