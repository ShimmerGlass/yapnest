// Adds a processed TestFlight build to a beta group, and for an external group
// submits it to Beta App Review if it hasn't been.
//
// swift dev/testflight-group.swift <key.p8> <key id> <issuer id> <bundle id> <version> <build> <IOS|MAC_OS> <group name>

import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 9 else {
    FileHandle.standardError.write(Data("usage: testflight-group.swift key.p8 keyID issuerID bundleID version build IOS|MAC_OS group\n".utf8))
    exit(2)
}
let (keyPath, keyID, issuer, bundleID, version, build, platform, groupName) = (args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8])

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("testflight-group: \(message)\n".utf8))
    exit(1)
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

func token() -> String {
    guard let pem = try? String(contentsOfFile: keyPath, encoding: .utf8),
          let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else { fail("can't read the key") }
    let now = Int(Date().timeIntervalSince1970)
    let header = base64URL(try! JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"]))
    let claims = base64URL(try! JSONSerialization.data(withJSONObject: ["iss": issuer, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"]))
    let signature = try! key.signature(for: Data("\(header).\(claims)".utf8))
    return "\(header).\(claims).\(base64URL(signature.rawRepresentation))"
}

@discardableResult
func request(_ method: String, _ path: String, _ body: [String: Any]? = nil, allowing: Set<Int> = []) -> (Int, [String: Any]) {
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
    guard (200..<300).contains(status) || allowing.contains(status) else { fail("\(method) \(path) answered \(status): \(text)") }
    return (status, (result.0.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:])
}

func items(_ response: (Int, [String: Any])) -> [[String: Any]] { response.1["data"] as? [[String: Any]] ?? [] }

func query(_ pairs: [(String, String)]) -> String {
    var components = URLComponents()
    components.queryItems = pairs.map { URLQueryItem(name: $0.0, value: $0.1) }
    return components.percentEncodedQuery ?? ""
}

guard let app = items(request("GET", "/v1/apps?" + query([("filter[bundleId]", bundleID)]))).first?["id"] as? String else {
    fail("no app with bundle id \(bundleID)")
}
let groups = items(request("GET", "/v1/betaGroups?" + query([("filter[app]", app), ("limit", "200")])))
let names = groups.compactMap { ($0["attributes"] as? [String: Any])?["name"] as? String }
guard let group = groups.first(where: { (($0["attributes"] as? [String: Any])?["name"] as? String)?.caseInsensitiveCompare(groupName) == .orderedSame }),
      let groupID = group["id"] as? String else { fail("no beta group named \(groupName); there are: \(names)") }
let isInternal = (group["attributes"] as? [String: Any])?["isInternalGroup"] as? Bool ?? false

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

request("POST", "/v1/betaGroups/\(groupID)/relationships/builds", ["data": [["type": "builds", "id": buildID]]])
print("\(platform) build \(build): added to \(groupName)")

guard !isInternal else { exit(0) }
// An external group sees a build only once Beta App Review has passed it.
let (status, existing) = request("GET", "/v1/builds/\(buildID)/betaAppReviewSubmission", allowing: [404])
if status != 404, let data = existing["data"] as? [String: Any], let state = (data["attributes"] as? [String: Any])?["betaReviewState"] as? String {
    print("\(platform) build \(build): beta review \(state.lowercased())")
} else {
    let (_, submitted) = request("POST", "/v1/betaAppReviewSubmissions", ["data": [
        "type": "betaAppReviewSubmissions",
        "relationships": ["build": ["data": ["type": "builds", "id": buildID]]],
    ]])
    let state = ((submitted["data"] as? [String: Any])?["attributes"] as? [String: Any])?["betaReviewState"] as? String ?? "submitted"
    print("\(platform) build \(build): sent to beta review (\(state.lowercased()))")
}
