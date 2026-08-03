import Foundation

enum AuthReader {
    /// Read non-secret identity fields from a profile's auth.json.
    static func identity(at authURL: URL) -> AccountIdentity {
        guard FileManager.default.fileExists(atPath: authURL.path) else {
            return AccountIdentity(email: nil, displayName: nil, userID: nil, isLoggedIn: false)
        }

        do {
            let data = try Data(contentsOf: authURL)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return AccountIdentity(email: nil, displayName: nil, userID: nil, isLoggedIn: false)
            }

            // auth.json is a map of provider-key -> session object
            for (_, value) in root {
                guard let session = value as? [String: Any] else { continue }
                let email = session["email"] as? String
                let first = session["first_name"] as? String
                let last = session["last_name"] as? String
                let userID = (session["user_id"] as? String) ?? (session["principal_id"] as? String)

                let nameParts = [first, last].compactMap { part -> String? in
                    guard let part, !part.isEmpty else { return nil }
                    return part
                }
                let displayName = nameParts.isEmpty ? nil : nameParts.joined(separator: "")

                let hasToken = (session["refresh_token"] as? String)?.isEmpty == false
                    || (session["access_token"] as? String)?.isEmpty == false
                    || (session["key"] as? String)?.isEmpty == false

                if email != nil || hasToken {
                    return AccountIdentity(
                        email: email,
                        displayName: displayName,
                        userID: userID,
                        isLoggedIn: true
                    )
                }
            }
        } catch {
            // Treat unreadable auth as logged-out for UI purposes.
        }

        return AccountIdentity(email: nil, displayName: nil, userID: nil, isLoggedIn: false)
    }
}
