#!/usr/bin/env swift
// Builds, checks, signs and publishes Zephydian packs (see docs/PACKS.md).
// Uses only what ships with macOS (CryptoKit, JavaScriptCore, ditto), so there's nothing to install.
//
//   swift scripts/packs.swift check [packs]                 check every pack under packs/
//   swift scripts/packs.swift build packs/games/lights      build one pack into dist/packs/
//   swift scripts/packs.swift keygen                        make a new signing key pair (once)
//   swift scripts/packs.swift publish packs dist/packs \
//       --base-url URL [--previous old-catalog.json]        build changed packs, write + sign catalog.json
//   swift scripts/packs.swift verify catalog.json catalog.json.sig PUBLIC_KEY
//
// publish reads the private key from the PACK_SIGNING_KEY environment variable (base64).
import CryptoKit
import Foundation
import JavaScriptCore

let sdkVersion = 1                       // the newest SDK version the tools (and app) know
let maxPackBytes = 5 * 1024 * 1024
let maxScriptBytes = 512 * 1024
let kinds = ["games": "game", "utilities": "utility"]
let assetExtensions: Set<String> = ["png", "json", "txt"]

struct Failure: Error, CustomStringConvertible { let description: String }
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

// MARK: - Manifest

struct Manifest: Codable {
    var id: String
    var name: String
    var kind: String
    var version: String
    var sdkVersion: Int
    var description: String
    var hint: String?
    var pauseButton: Bool?
    var tileStat: String?
    var whatsNew: String?
}

/// "1.2.3" → [1, 2, 3]; nil if it isn't three whole numbers.
func parseVersion(_ v: String) -> [Int]? {
    let parts = v.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
    guard parts.count == 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
    return parts.map { $0! }
}

// MARK: - Checking a pack folder

struct Pack {
    let folder: URL
    let manifest: Manifest
    let files: [String]           // relative paths, sorted
    let sourceHash: String        // fingerprint of the sources, to spot changes without a version bump
}

func pngSize(_ data: Data) -> (Int, Int)? {
    let sig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    guard data.count >= 24, Array(data.prefix(8)) == sig else { return nil }
    func be32(_ o: Int) -> Int { data[o..<o + 4].reduce(0) { $0 << 8 | Int($1) } }
    return (be32(16), be32(20))
}

func checkPack(_ folder: URL) throws -> Pack {
    let fm = FileManager.default
    let id = folder.lastPathComponent
    let where_ = "\(folder.deletingLastPathComponent().lastPathComponent)/\(id)"
    func problem(_ s: String) -> Failure { Failure(description: "\(where_): \(s)") }

    // Files: a fixed allow-list, nothing else.
    var files: [String] = []
    var total = 0
    let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])!
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let rel = String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1))
        if url.lastPathComponent == ".DS_Store" { continue }
        if values.isSymbolicLink == true { throw problem("\(rel) is a symbolic link, which packs can't contain") }
        guard values.isRegularFile == true else { continue }
        let allowed = ["manifest.json", "main.js", "icon.png"].contains(rel)
            || (rel.hasPrefix("assets/") && assetExtensions.contains(url.pathExtension.lowercased())
                && !url.lastPathComponent.hasPrefix("."))
        guard allowed else {
            throw problem("\(rel) isn't allowed. A pack holds manifest.json, main.js, icon.png and assets/ (PNG, JSON, TXT)")
        }
        total += values.fileSize ?? 0
        files.append(rel)
    }
    files.sort()
    for required in ["manifest.json", "main.js", "icon.png"] where !files.contains(required) {
        throw problem("\(required) is missing")
    }
    if total > maxPackBytes { throw problem("the pack is \(total / 1024) KB; the limit is \(maxPackBytes / 1024) KB") }

    // manifest.json
    let manifestData = try Data(contentsOf: folder.appending(path: "manifest.json"))
    let m: Manifest
    do { m = try JSONDecoder().decode(Manifest.self, from: manifestData) } catch {
        throw problem("manifest.json can't be read: \(error)")
    }
    if m.id != id { throw problem("manifest id \"\(m.id)\" must match the folder name \"\(id)\"") }
    if m.id.range(of: #"^[a-z0-9][a-z0-9-]{0,31}$"#, options: .regularExpression) == nil {
        throw problem("id must be lowercase letters, digits and -, at most 32 characters")
    }
    let expectedKind = kinds[folder.deletingLastPathComponent().lastPathComponent]
    if m.kind != expectedKind { throw problem("kind must be \"\(expectedKind ?? "?")\" for a pack in this folder") }
    if m.kind != "game" { throw problem("SDK \(sdkVersion) supports games only") }
    if m.name.trimmingCharacters(in: .whitespaces).isEmpty || m.name.count > 24 { throw problem("name must be 1–24 characters") }
    if m.kind == "game" && m.name.contains(" ") { throw problem("game names are a single word") }
    if parseVersion(m.version) == nil { throw problem("version must look like 1.0.0") }
    if !(1...sdkVersion).contains(m.sdkVersion) { throw problem("sdkVersion must be between 1 and \(sdkVersion)") }
    if m.description.isEmpty || m.description.count > 90 { throw problem("description must be 1–90 characters") }
    if let s = m.tileStat, !["bestScore", "bestTime", "none"].contains(s) {
        throw problem("tileStat must be bestScore, bestTime or none")
    }

    // icon.png: 64 × 64
    let icon = try Data(contentsOf: folder.appending(path: "icon.png"))
    guard let (w, h) = pngSize(icon), w == 64, h == 64 else { throw problem("icon.png must be a 64 × 64 PNG") }

    // main.js: size and syntax (checked without running it)
    let script = try Data(contentsOf: folder.appending(path: "main.js"))
    if script.count > maxScriptBytes { throw problem("main.js is over \(maxScriptBytes / 1024) KB") }
    guard let source = String(data: script, encoding: .utf8) else { throw problem("main.js must be UTF-8") }
    let ctx = JSGlobalContextCreate(nil)!
    defer { JSGlobalContextRelease(ctx) }
    let js = JSStringCreateWithUTF8CString(source)!
    defer { JSStringRelease(js) }
    var exception: JSValueRef?
    if !JSCheckScriptSyntax(ctx, js, nil, 1, &exception) {
        let message = exception.flatMap { JSValueToStringCopy(ctx, $0, nil) }.map { JSStringCopyCFString(nil, $0) as String } ?? "syntax error"
        throw problem("main.js: \(message)")
    }

    // Fingerprint of the sources: every file's path and bytes, in order.
    var hasher = SHA256()
    for rel in files {
        hasher.update(data: Data(rel.utf8 + [0]))
        let bytes = try Data(contentsOf: folder.appending(path: rel))
        withUnsafeBytes(of: UInt64(bytes.count).bigEndian) { hasher.update(bufferPointer: $0) }
        hasher.update(data: bytes)
    }
    let sourceHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return Pack(folder: folder, manifest: m, files: files, sourceHash: sourceHash)
}

func packFolders(in root: URL) -> [URL] {
    let fm = FileManager.default
    var result: [URL] = []
    for kind in kinds.keys.sorted() {
        let dir = root.appending(path: kind)
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            result.append(item)
        }
    }
    return result
}

// MARK: - Building a .zpack

func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

func run(_ tool: String, _ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(filePath: tool)
    p.arguments = args
    try p.run()
    p.waitUntilExit()
    if p.terminationStatus != 0 { throw Failure(description: "\(tool) failed") }
}

/// Copies only the allowed files to a clean folder, then zips it (contents at the zip's root).
func buildZpack(_ pack: Pack, into out: URL) throws -> URL {
    let fm = FileManager.default
    let stage = fm.temporaryDirectory.appending(path: "zpack-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: stage) }
    for rel in pack.files {
        let dst = stage.appending(path: rel)
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: pack.folder.appending(path: rel), to: dst)
    }
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    let file = out.appending(path: "\(pack.manifest.id)-\(pack.manifest.version).zpack")
    try? fm.removeItem(at: file)
    try run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl", stage.path, file.path])
    return file
}

// MARK: - Catalog

struct CatalogEntry: Codable {
    var id, name, kind, version: String
    var sdkVersion: Int
    var description: String
    var whatsNew: String?
    var size: Int
    var url: String
    var sha256: String
    var iconURL: String
    var iconSha256: String
    var sourceHash: String
}

struct Catalog: Codable {
    var format = 1
    /// Seconds since 1970. The app refuses a catalog older than one it has already seen.
    var sequence: Int
    var generated: String
    var packs: [CatalogEntry]
}

func encodeCatalog(_ c: Catalog) throws -> Data {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try e.encode(c)
}

func signingKey() -> Curve25519.Signing.PrivateKey {
    guard let b64 = ProcessInfo.processInfo.environment["PACK_SIGNING_KEY"], !b64.isEmpty else {
        fail("PACK_SIGNING_KEY isn't set")
    }
    guard let raw = Data(base64Encoded: b64.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("PACK_SIGNING_KEY isn't a valid key (expected the base64 text from `keygen`)")
    }
    return key
}

// MARK: - Commands

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...i + 1)
    return value
}
let cwd = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
func path(_ s: String) -> URL { URL(filePath: s, relativeTo: cwd).standardizedFileURL }

switch args.first {
case "check":
    let root = path(args.count > 1 ? args[1] : "packs")
    let folders = packFolders(in: root)
    var ids = Set<String>(), failed = false
    for folder in folders {
        do {
            let p = try checkPack(folder)
            if !ids.insert(p.manifest.id).inserted { throw Failure(description: "\(p.manifest.id): the id is used twice") }
            print("ok  \(p.manifest.id) \(p.manifest.version)")
        } catch {
            print("error: \(error)")
            failed = true
        }
    }
    if folders.isEmpty { print("No packs under \(root.path)") }
    exit(failed ? 1 : 0)

case "build":
    guard args.count > 1 else { fail("usage: build <pack folder> [output folder]") }
    do {
        let pack = try checkPack(path(args[1]))
        let file = try buildZpack(pack, into: path(args.count > 2 ? args[2] : "dist/packs"))
        let data = try Data(contentsOf: file)
        print("Built \(file.path) (\(data.count / 1024) KB)\nSHA-256: \(sha256Hex(data))")
    } catch { fail("\(error)") }

case "keygen":
    let key = Curve25519.Signing.PrivateKey()
    print("""
    PRIVATE key (secret: save it as the PACK_SIGNING_KEY repository secret and in your password manager, nowhere else):
    \(key.rawRepresentation.base64EncodedString())

    PUBLIC key (not secret: this goes into the app):
    \(key.publicKey.rawRepresentation.base64EncodedString())
    """)

case "publish":
    guard let baseURL = option("--base-url") else { fail("publish needs --base-url") }
    let previousPath = option("--previous")
    guard args.count > 2 else { fail("usage: publish <packs folder> <output folder> --base-url URL [--previous catalog.json]") }
    let key = signingKey()
    let out = path(args[2])
    do {
        var previous: [String: CatalogEntry] = [:]
        if let previousPath, let data = try? Data(contentsOf: path(previousPath)) {
            let old = try JSONDecoder().decode(Catalog.self, from: data)
            previous = Dictionary(uniqueKeysWithValues: old.packs.map { ($0.id, $0) })
        }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var entries: [CatalogEntry] = []
        for folder in packFolders(in: path(args[1])) {
            let pack = try checkPack(folder)
            let m = pack.manifest
            if let old = previous[m.id] {
                let oldV = parseVersion(old.version) ?? [0, 0, 0], newV = parseVersion(m.version)!
                if newV == oldV {
                    guard old.sourceHash == pack.sourceHash else {
                        throw Failure(description: "\(m.id) changed but its version is still \(m.version). Raise the version in manifest.json")
                    }
                    entries.append(old)                    // unchanged: keep the published file
                    print("same \(m.id) \(m.version)")
                    continue
                }
                if newV.lexicographicallyPrecedes(oldV) {
                    throw Failure(description: "\(m.id) \(m.version) is older than the published \(old.version)")
                }
            }
            let file = try buildZpack(pack, into: out)
            let data = try Data(contentsOf: file)
            let iconName = "\(m.id)-\(m.version).png"
            let icon = try Data(contentsOf: folder.appending(path: "icon.png"))
            try icon.write(to: out.appending(path: iconName))
            entries.append(CatalogEntry(
                id: m.id, name: m.name, kind: m.kind, version: m.version, sdkVersion: m.sdkVersion,
                description: m.description, whatsNew: m.whatsNew, size: data.count,
                url: "\(baseURL)/\(file.lastPathComponent)", sha256: sha256Hex(data),
                iconURL: "\(baseURL)/\(iconName)", iconSha256: sha256Hex(icon), sourceHash: pack.sourceHash))
            print("new  \(m.id) \(m.version)")
        }
        let now = Date()
        let catalog = Catalog(sequence: Int(now.timeIntervalSince1970),
                              generated: ISO8601DateFormatter().string(from: now), packs: entries)
        let catalogData = try encodeCatalog(catalog)
        try catalogData.write(to: out.appending(path: "catalog.json"))
        let signature = try key.signature(for: catalogData)
        try Data(signature.base64EncodedString().utf8).write(to: out.appending(path: "catalog.json.sig"))
        print("Signed catalog.json with \(entries.count) pack(s). Public key: \(key.publicKey.rawRepresentation.base64EncodedString())")
    } catch { fail("\(error)") }

case "verify":
    guard args.count == 4 else { fail("usage: verify catalog.json catalog.json.sig PUBLIC_KEY") }
    guard let catalog = try? Data(contentsOf: path(args[1])),
          let sigText = try? String(contentsOf: path(args[2]), encoding: .utf8),
          let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)),
          let keyData = Data(base64Encoded: args[3]),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { fail("can't read the inputs") }
    if key.isValidSignature(sig, for: catalog) { print("Signature OK") } else { fail("signature does NOT match") }

default:
    print("usage: swift scripts/packs.swift check | build | keygen | publish | verify   (see the top of this file)")
    exit(args.isEmpty ? 0 : 1)
}
