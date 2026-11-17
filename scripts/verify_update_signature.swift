// Checks a Sparkle EdDSA (Ed25519) signature against a public key, as the app
// will: no keychain access, so release.sh can prove the appcast entry and the
// signed feed verify with the SUPublicEDKey the shipped app carries (#24, #46).
//
// Usage: swift scripts/verify_update_signature.swift <SUPublicEDKey> <edSignature> <file>
//        swift scripts/verify_update_signature.swift --feed <SUPublicEDKey> <appcast.xml>
//
// --feed: `sign_update` embeds the feed's signature as a trailing
// `<!-- sparkle-signatures: edSignature: ... length: N -->` comment; what it
// signs is every byte before that comment. Fails if the comment is missing, the
// recorded length is wrong, or the signature doesn't verify.
import CryptoKit
import Foundation

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

var args = Array(CommandLine.arguments.dropFirst())
let feedMode = args.first == "--feed"
if feedMode { args.removeFirst() }
guard args.count == (feedMode ? 2 : 3) else {
    fail("usage: verify_update_signature.swift <public-key-b64> <signature-b64> <file>\n       verify_update_signature.swift --feed <public-key-b64> <appcast.xml>", 2)
}
guard let keyData = Data(base64Encoded: args[0]), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
      let file = FileManager.default.contents(atPath: args[feedMode ? 1 : 2]) else {
    fail("error: bad key or file", 2)
}

var signedBytes = file
var signatureB64 = feedMode ? "" : args[1]
if feedMode {
    let marker = "<!-- sparkle-signatures:\n".data(using: .utf8)!
    guard let r = file.range(of: marker, options: .backwards) else {
        fail("error: the feed carries no embedded signature (sign_update on the XML)", 1)
    }
    signedBytes = file.subdata(in: file.startIndex..<r.lowerBound)
    let tail = String(decoding: file.subdata(in: r.lowerBound..<file.endIndex), as: UTF8.self)
    func field(_ name: String) -> String? {
        for line in tail.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(name + ":") { return t.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }
    guard let sig = field("edSignature") else { fail("error: embedded signature has no edSignature", 1) }
    signatureB64 = sig
    if let len = field("length"), Int(len) != signedBytes.count {
        fail("error: feed length \(signedBytes.count) != recorded \(len): modified after signing", 1)
    }
}
guard let signature = Data(base64Encoded: signatureB64) else { fail("error: bad signature", 2) }
guard key.isValidSignature(signature, for: signedBytes) else {
    fail("error: EdDSA signature does NOT verify with this public key", 1)
}
print("EdDSA signature verifies with \(args[0])")
