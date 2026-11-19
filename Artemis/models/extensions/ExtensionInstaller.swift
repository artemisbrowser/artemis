// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import CryptoKit
import Foundation
import Security

/// stores every install source under `Extensions/<id>/` as a file URL `WKWebExtension` loads:
/// a directory holding `manifest.json`, or a zip (an `.xpi` as-is, a `.crx` without its header)
nonisolated enum ExtensionInstaller {
    enum InstallError: LocalizedError {
        case notReadable
        case noManifest
        case holdsLink
        case unproven
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .notReadable: "The extension file couldn't be read."
            case .noManifest: "No manifest.json was found in the extension."
            case .holdsLink: "The extension holds a symbolic link or can't be unpacked, so Artemis won't install it."
            case .unproven: "This package's signature doesn't match its contents, so Artemis won't install it."
            case .copyFailed(let why): "Couldn't store the extension: \(why)"
            }
        }
    }

    /// root folder that holds every installed extension's resources
    static var storageRoot: URL {
        AppStorageLocation.directory.appendingPathComponent("Extensions", isDirectory: true)
    }

    /// the on-disk resource URL for a stored extension id (dir or archive)
    static func resourceURL(forStoredID id: String) -> URL? {
        let dir = storageRoot.appendingPathComponent(id, isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        else { return nil }
        if let archive = entries.first(where: { $0.lastPathComponent == "extension.zip" }) {
            return archive
        }
        return manifestRoot(under: dir)
    }

    /// copy a source (folder, .zip, .xpi, .crx, or a Safari extension's app) into storage, returning
    /// its stored id. `fromStore` is for an archive Artemis downloaded from the store itself
    @concurrent static func install(from picked: URL, fromStore: Bool = false) async throws -> String {
        let fm = FileManager.default
        let source = safariResources(in: picked) ?? picked
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir),
            let data = isDir.boolValue ? Data() : try? Data(contentsOf: source)
        else { throw InstallError.notReadable }
        let kind = isDir.boolValue ? "" : source.pathExtension.lowercased()
        // a CRX keeps the id its signature proves, so `runtime.id` matches what
        // the extension and the sites it talks to expect
        let crx = kind == "crx" ? proven(crx: data) : nil
        guard kind != "crx" || crx != nil else { throw InstallError.unproven }
        let storeID = crx?.id
        try fm.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        // creating the folder is what claims the id; a store id already taken leaves a fresh one
        let claimed = storeID.flatMap { id in
            (try? fm.createDirectory(at: storageRoot.appendingPathComponent(id), withIntermediateDirectories: false))
                .map { _ in id }
        }
        let id = claimed ?? UUID().uuidString.lowercased()
        let dest = storageRoot.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        do {
            if isDir.boolValue {
                let entries = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                for entry in entries {
                    try fm.copyItem(at: entry, to: dest.appendingPathComponent(entry.lastPathComponent))
                }
                // the origin sidecar is the installer's to write; the volume may match its name in any case
                try? fm.removeItem(at: dest.appendingPathComponent(packageOriginFile))
                guard let root = manifestRoot(under: dest) else { throw InstallError.noManifest }
                try ExtensionCompat.stripPatchKeys(packageRoot: root)
            } else {
                try (crx?.archive ?? data).write(to: dest.appendingPathComponent("extension.zip"))
                if let origin = storeID ?? (kind == "xpi" ? (fromStore ? "xpi" : unverifiedXPI) : nil) {
                    try? origin.write(
                        to: dest.appendingPathComponent(packageOriginFile), atomically: true,
                        encoding: .utf8)
                }
            }
            return id
        } catch let err as InstallError {
            try? fm.removeItem(at: dest)
            throw err
        } catch {
            try? fm.removeItem(at: dest)
            throw InstallError.copyFailed(error.localizedDescription)
        }
    }

    /// the web extension a Safari extension's `.app` or `.appex` carries; nil for anything else
    static func safariResources(in bundle: URL) -> URL? {
        let fm = FileManager.default
        let appexes: [URL] =
            switch bundle.pathExtension.lowercased() {
            case "appex": [bundle]
            case "app":
                (try? fm.contentsOfDirectory(
                    at: bundle.appendingPathComponent("Contents/PlugIns"), includingPropertiesForKeys: nil)) ?? []
            default: []
            }
        return appexes.sorted { $0.path < $1.path }.first {
            let info = NSDictionary(contentsOf: $0.appendingPathComponent("Contents/Info.plist"))
            return (info?["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String
                == "com.apple.Safari.web-extension"
        }?.appendingPathComponent("Contents/Resources", isDirectory: true)
    }

    /// drop a stored extension's resources from disk
    static func removeStorage(forID id: String) {
        try? FileManager.default.removeItem(at: storageRoot.appendingPathComponent(id, isDirectory: true))
    }

    // MARK: - Helpers

    /// the directory holding manifest.json, at `dir` or inside a chain of single wrapping folders
    static func manifestRoot(under dir: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) {
            return dir
        }
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey])
        else { return nil }
        let subdirs = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        if subdirs.count == 1 {
            return manifestRoot(under: subdirs[0])
        }
        return nil
    }

    /// sidecar beside a stored package: a CRX's proven id, `xpi` for a Firefox package Artemis
    /// downloaded from the store, `unverifiedXPI` for one picked from disk
    static let packageOriginFile = "package-origin"
    static let unverifiedXPI = "xpi-unverified"

    static func packageOrigin(forStoredID id: String) -> String? {
        try? String(
            contentsOf: storageRoot.appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent(packageOriginFile), encoding: .utf8)
    }

    /// a CRX3 package's id (16 bytes spelled as a–p nibbles) and zip, given only when every proof in
    /// its header verifies over both and one proof's key hashes to the header's `crx_id`
    static func proven(crx data: Data) -> (id: String, archive: Data)? {
        let start = [UInt8](data.prefix(12))
        guard start.count == 12, start.starts(with: Array("Cr24".utf8) + [3, 0, 0, 0]) else { return nil }
        let length = (8..<12).reduce(0) { $0 | Int(start[$1]) << (8 * ($1 - 8)) }
        guard length <= data.count - 12 else { return nil }
        let header = [UInt8](data.dropFirst(12).prefix(length))[...]
        let archive = data.dropFirst(12 + length)
        guard let signed = protobufValues(field: 10000, in: header).last,
            let id = protobufValues(field: 1, in: signed).last, id.count == 16
        else { return nil }
        var hash = SHA256()
        hash.update(data: Data("CRX3 SignedData\0".utf8))
        hash.update(data: withUnsafeBytes(of: UInt32(signed.count).littleEndian) { Data($0) })
        hash.update(data: signed)
        hash.update(data: archive)
        let digest = hash.finalize()
        var named = false
        for (field, rsa) in [(2, true), (3, false)] {
            for proof in protobufValues(field: field, in: header) {
                guard let key = protobufValues(field: 1, in: proof).first.map({ Data($0) }),
                    let signature = protobufValues(field: 2, in: proof).first.map({ Data($0) })
                else { return nil }
                let valid =
                    if rsa {
                        SecKeyCreateWithData(
                            key as CFData,
                            [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary,
                            nil
                        ).map {
                            SecKeyVerifySignature(
                                $0, .rsaSignatureDigestPKCS1v15SHA256, Data(digest) as CFData, signature as CFData, nil)
                        } ?? false
                    } else {
                        (try? P256.Signing.PublicKey(derRepresentation: key).isValidSignature(
                            P256.Signing.ECDSASignature(derRepresentation: signature), for: digest)) ?? false
                    }
                guard valid else { return nil }
                named = named || SHA256.hash(data: key).prefix(16).elementsEqual(id)
            }
        }
        guard named else { return nil }
        let letters = Array("abcdefghijklmnop")
        return (String(id.flatMap { [letters[Int($0 >> 4)], letters[Int($0 & 15)]] }), Data(archive))
    }

    /// every length-delimited value of `field` in a protobuf message
    private static func protobufValues(field: Int, in message: ArraySlice<UInt8>) -> [ArraySlice<UInt8>] {
        var found: [ArraySlice<UInt8>] = []
        var index = message.startIndex
        func varint() -> Int? {
            var value = 0
            for shift in stride(from: 0, to: 64, by: 7) where index < message.endIndex {
                let byte = message[index]
                index += 1
                value |= Int(byte & 0x7F) << shift
                if byte < 0x80 { return value }
            }
            return nil
        }
        while index < message.endIndex, let key = varint() {
            switch key & 7 {
            case 0: guard varint() != nil else { return [] }
            case 1: index += 8
            case 5: index += 4
            case 2:
                guard let length = varint(), length >= 0, length <= message.endIndex - index else { return [] }
                if key >> 3 == field { found.append(message[index..<(index + length)]) }
                index += length
            default: return []
            }
        }
        return index == message.endIndex ? found : []
    }
}
