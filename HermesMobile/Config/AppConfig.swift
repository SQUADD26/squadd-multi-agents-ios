import Foundation

enum AppConfig {
    static let privacyPolicyURL = URL(staticString: "https://squaddcrm.com/privacy-policy")
    static let supportURL = URL(staticString: "https://squaddcrm.com/contatti")
    /// Report a Problem in About: Squadd's contact page, like Support.
    static let reportProblemURL = supportURL
}

extension URL {
    init(staticString string: StaticString) {
        let value = string.withUTF8Buffer { String(decoding: $0, as: UTF8.self) }
        guard let url = URL(string: value) else {
            preconditionFailure("Invalid static URL literal: \(value)")
        }
        self = url
    }
}
