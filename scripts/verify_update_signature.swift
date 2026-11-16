// Checks a Sparkle EdDSA (Ed25519) signature against a public key, as the app
// will: no keychain access, so release.sh can prove the appcast entry verifies
// with the SUPublicEDKey the shipped app carries (#24).
//
// Usage: swift scripts/verify_update_signature.swift <SUPublicEDKey> <edSignature> <file>
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write("usage: verify_update_signature.swift <public-key-b64> <signature-b64> <file>\n".data(using: .utf8)!)
    exit(2)
}
guard let keyData = Data(base64Encoded: args[1]), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
      let signature = Data(base64Encoded: args[2]),
      let file = FileManager.default.contents(atPath: args[3]) else {
    FileHandle.standardError.write("error: bad key, signature or file\n".data(using: .utf8)!)
    exit(2)
}
guard key.isValidSignature(signature, for: file) else {
    FileHandle.standardError.write("error: EdDSA signature does NOT verify with this public key\n".data(using: .utf8)!)
    exit(1)
}
print("EdDSA signature verifies with \(args[1])")
