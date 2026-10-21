// Sets a TestFlight build's "What to Test" through the App Store Connect API,
// once Apple has processed the upload.
//
// swift dev/testflight-notes.swift <key.p8> <key id> <issuer id> <bundle id> <version> <build> <IOS|MAC_OS> <notes.md>

import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 9 else {
    FileHandle.standardError.write(Data("usage: testflight-notes.swift key.p8 keyID issuerID bundleID version build IOS|MAC_OS notes.md\n".utf8))
    exit(2)
}
let (keyPath, keyID, issuer, bundleID, version, build, platform, notesPath) = (args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8])

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("testflight-notes: \(message)\n".utf8))
    exit(1)
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

// A fresh token per request: they last 20 minutes at most, and processing can take longer.
func token() -> String {
    guard let pem = try? String(contentsOfFile: keyPath, encoding: .utf8),
          let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else { fail("can't read the key") }
    let now = Int(Date().timeIntervalSince1970)
    let header = base64URL(try! JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"]))
    let claims = base64URL(try! JSONSerialization.data(withJSONObject: ["iss": issuer, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"]))
    let signature = try! key.signature(for: Data("\(header).\(claims)".utf8))
    return "\(header).\(claims).\(base64URL(signature.rawRepresentation))"
}

func request(_ method: String, _ path: String, _ body: [String: Any]? = nil) -> [String: Any] {
    var request = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com" + path)!)
    request.httpMethod = method
    request.setValue("Bearer \(token())", forHTTPHeaderField: "Authorization")
    if let body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try! JSONSerialization.data(withJSONObject: body)
    }
    let done = DispatchSemaphore(value: 0)
    var result: (Data?, URLResponse?) = (nil, nil)
    URLSession.shared.dataTask(with: request) { data, response, _ in
        result = (data, response)
        done.signal()
    }.resume()
    done.wait()
    let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
    let text = result.0.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    guard (200..<300).contains(status) else { fail("\(method) \(path) answered \(status): \(text)") }
    return (result.0.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
}

func items(_ response: [String: Any]) -> [[String: Any]] { response["data"] as? [[String: Any]] ?? [] }

func query(_ pairs: [(String, String)]) -> String {
    var components = URLComponents()
    components.queryItems = pairs.map { URLQueryItem(name: $0.0, value: $0.1) }
    return components.percentEncodedQuery ?? ""
}

guard var notes = try? String(contentsOfFile: notesPath, encoding: .utf8) else { fail("can't read \(notesPath)") }
// The title repeats what TestFlight already shows.
if notes.hasPrefix("# ") { notes = notes.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().joined().trimmingCharacters(in: .whitespacesAndNewlines) }
guard notes.count <= 4000 else { fail("the notes are \(notes.count) characters; TestFlight takes 4,000") }

guard let app = items(request("GET", "/v1/apps?" + query([("filter[bundleId]", bundleID)]))).first?["id"] as? String else {
    fail("no app with bundle id \(bundleID)")
}

// Uploaded builds take a while to show up, then to process.
let deadline = Date().addingTimeInterval(60 * 60)
var buildID: String?
while Date() < deadline {
    let found = items(request("GET", "/v1/builds?" + query([
        ("filter[app]", app), ("filter[version]", build),
        ("filter[preReleaseVersion.version]", version), ("filter[preReleaseVersion.platform]", platform),
    ])))
    if let first = found.first, let attributes = first["attributes"] as? [String: Any] {
        let state = attributes["processingState"] as? String ?? ""
        if state == "VALID" { buildID = first["id"] as? String; break }
        if state == "FAILED" || state == "INVALID" { fail("build \(version) (\(build)) on \(platform) is \(state)") }
        print("\(platform) build \(build): \(state.lowercased())")
    } else {
        print("\(platform) build \(build): not listed yet")
    }
    Thread.sleep(forTimeInterval: 60)
}
guard let buildID else { fail("build \(version) (\(build)) on \(platform) wasn't processed within an hour") }

let localizations = items(request("GET", "/v1/builds/\(buildID)/betaBuildLocalizations"))
if let existing = localizations.first(where: { ($0["attributes"] as? [String: Any])?["locale"] as? String == "en-US" }) ?? localizations.first,
   let id = existing["id"] as? String {
    _ = request("PATCH", "/v1/betaBuildLocalizations/\(id)", ["data": ["type": "betaBuildLocalizations", "id": id, "attributes": ["whatsNew": notes]]])
} else {
    _ = request("POST", "/v1/betaBuildLocalizations", ["data": [
        "type": "betaBuildLocalizations",
        "attributes": ["locale": "en-US", "whatsNew": notes],
        "relationships": ["build": ["data": ["type": "builds", "id": buildID]]],
    ]])
}
print("\(platform) build \(build): What to Test set")
