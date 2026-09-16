import Foundation
import os

enum Log {
    private static let subsystem = "com.github.aspan21.clipnotch"
    static let media = Logger(subsystem: subsystem, category: "media")
    static let clipboard = Logger(subsystem: subsystem, category: "clipboard")
    static let paste = Logger(subsystem: subsystem, category: "paste")
    static let notch = Logger(subsystem: subsystem, category: "notch")
}
