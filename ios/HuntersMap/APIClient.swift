import Foundation
import FirebaseAuth

// Client for the hunters-map backend (backend/, Cloud Run). Every call carries the signed-in
// user's Firebase ID token; the base URL is HuntersMapAPIBaseURL in HuntersMap-Info.plist.

struct Profile: Codable, Equatable {
    let id: String
    let displayName: String
    let email: String
    let createdAt: Date
}

struct HuntingGroup: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let ownerId: String
    let createdAt: Date
    let role: String?
    let sharingUntil: Date?
    let members: [GroupMember]?
}

struct GroupMember: Codable, Identifiable, Equatable {
    let userId: String
    let displayName: String
    let role: String
    let joinedAt: Date
    let sharingUntil: Date?

    var id: String { userId }
}

struct GroupInvite: Codable, Equatable {
    let code: String
    let groupId: String
    let expiresAt: Date
}

struct SharingState: Codable, Equatable {
    let sharing: Bool
    let until: Date?
}

enum APIError: LocalizedError {
    case notSignedIn
    case server(status: Int, code: String, message: String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Et ole kirjautunut sisään."
        case .server(_, _, let message): message
        case .badResponse: "Palvelin vastasi odottamattomasti."
        }
    }
}

final class APIClient {
    static let shared = APIClient()

    let baseURL: URL
    private let session = URLSession(configuration: .default)
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: URL? = nil) {
        let configured = Bundle.main.object(forInfoDictionaryKey: "HuntersMapAPIBaseURL") as? String
        self.baseURL = baseURL ?? URL(string: configured ?? "")!

        // Go encodes times as RFC 3339, with fractional seconds when there are any.
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            if let date = precise.date(from: s) ?? plain.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "bad date \(s)"))
        }
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
    }

    // MARK: Profile

    func me() async throws -> Profile {
        try await send("GET", "/v1/me")
    }

    func updateProfile(displayName: String) async throws -> Profile {
        try await send("PUT", "/v1/me", body: ["displayName": displayName])
    }

    func deleteAccount() async throws {
        let _: Empty = try await send("DELETE", "/v1/me")
    }

    // MARK: Groups

    func groups() async throws -> [HuntingGroup] {
        struct List: Decodable { let groups: [HuntingGroup] }
        let list: List = try await send("GET", "/v1/groups")
        return list.groups
    }

    func createGroup(name: String) async throws -> HuntingGroup {
        try await send("POST", "/v1/groups", body: ["name": name])
    }

    func group(id: String) async throws -> HuntingGroup {
        try await send("GET", "/v1/groups/\(id)")
    }

    func deleteGroup(id: String) async throws {
        let _: Empty = try await send("DELETE", "/v1/groups/\(id)")
    }

    func createInvite(groupID: String) async throws -> GroupInvite {
        try await send("POST", "/v1/groups/\(groupID)/invites")
    }

    func join(code: String) async throws -> HuntingGroup {
        let code = code.trimmingCharacters(in: .whitespaces).uppercased()
        return try await send("POST", "/v1/invites/\(code)/join")
    }

    func removeMember(groupID: String, userID: String) async throws {
        let _: Empty = try await send("DELETE", "/v1/groups/\(groupID)/members/\(userID)")
    }

    // MARK: Sharing

    /// Starts sharing until the given time (the backend caps it to 24 h), or stops with nil.
    func setSharing(groupID: String, until: Date?) async throws -> SharingState {
        struct Body: Encodable { let until: Date? }
        return try await send("PUT", "/v1/groups/\(groupID)/sharing", body: Body(until: until))
    }

    /// Sends the latest position; returns the groups it was shared with.
    func postLocation(_ location: SharedLocation) async throws -> [String] {
        struct Reply: Decodable { let groups: [String] }
        let reply: Reply = try await send("POST", "/v1/locations", body: location)
        return reply.groups
    }

    // MARK: Transport

    private struct Empty: Decodable {}

    /// The backend's error shape: {"error": {"code": "...", "message": "..."}}.
    private struct ErrorBody: Decodable {
        struct Inner: Decodable { let code: String; let message: String }
        let error: Inner
    }

    private func send<T: Decodable>(_ method: String, _ path: String, body: (any Encodable)? = nil) async throws -> T {
        guard let user = Auth.auth().currentUser else { throw APIError.notSignedIn }
        let token = try await user.getIDToken()

        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            if let err = try? decoder.decode(ErrorBody.self, from: data) {
                throw APIError.server(status: http.statusCode, code: err.error.code, message: err.error.message)
            }
            throw APIError.server(status: http.statusCode, code: "http", message: "HTTP \(http.statusCode)")
        }
        if T.self == Empty.self { return Empty() as! T }
        return try decoder.decode(T.self, from: data)
    }
}

/// Body of POST /v1/locations.
struct SharedLocation: Encodable {
    let lat: Double
    let lon: Double
    let accuracy: Double
    let heading: Double?
    let speed: Double?
    let recordedAt: Date
}
