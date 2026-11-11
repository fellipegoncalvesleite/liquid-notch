import CryptoKit
import Foundation

// Signs Liquid Notch's update files for Sparkle (EdDSA = Ed25519 over the file's bytes, which Sparkle checks against
// SUPublicEDKey in the app's Info.plist). Built and run by tools/updates.sh.
//
//   tools/updates.sh keygen            new update-signing key (refuses to overwrite one)
//   tools/updates.sh pubkey            the public key for SUPublicEDKey in Resources/Info.plist
//   tools/updates.sh sign <file>       prints sparkle:edSignature="…" length="…" for the appcast
//
// The private key lives only in ~/.config/liquid-notch/update-signing.key (0600). Lose it and no new update can be
// installed by existing copies; leak it and someone could push a fake update. Back it up.

let keyFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/liquid-notch/update-signing.key")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOf: keyFile, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("No update-signing key at \(keyFile.path). Run: tools/updates.sh keygen")
    }
    return key
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "keygen":
    guard !FileManager.default.fileExists(atPath: keyFile.path) else {
        fail("\(keyFile.path) already exists. Every installed copy trusts it; move it away yourself if you really mean it.")
    }
    try FileManager.default.createDirectory(at: keyFile.deletingLastPathComponent(), withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    let key = Curve25519.Signing.PrivateKey()
    FileManager.default.createFile(atPath: keyFile.path, contents: Data((key.rawRepresentation.base64EncodedString() + "\n").utf8),
                                   attributes: [.posixPermissions: 0o600])
    print("Update-signing key written to \(keyFile.path) (0600). Back it up.")
    print("SUPublicEDKey: \(key.publicKey.rawRepresentation.base64EncodedString())")
case "pubkey":
    print(loadKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard args.count == 2 else { fail("usage: tools/updates.sh sign <file>") }
    guard let data = FileManager.default.contents(atPath: args[1]) else { fail("Can't read \(args[1])") }
    let key = loadKey()
    let signature = try key.signature(for: data)
    guard key.publicKey.isValidSignature(signature, for: data) else { fail("Signature failed its own check.") }
    print("sparkle:edSignature=\"\(signature.base64EncodedString())\" length=\"\(data.count)\"")
default:
    fail("usage: tools/updates.sh keygen | pubkey | sign <file>")
}
