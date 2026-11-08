// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// stores every install source under `Extensions/<id>/` as a file URL `WKWebExtension` loads:
/// a directory holding `manifest.json`, or a zip (an `.xpi` as-is, a `.crx` without its header)
nonisolated enum ExtensionInstaller {
    enum InstallError: LocalizedError {
        case notReadable
        case noManifest
        case holdsLink
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .notReadable: "The extension file couldn't be read."
            case .noManifest: "No manifest.json was found in the extension."
            case .holdsLink: "The extension contains a symbolic link, which Artemis won't install."
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

    /// copy a sideloaded source (folder, .zip, .xpi, or .crx) into storage, returning its stored id
    @concurrent static func install(from source: URL) async throws -> String {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else {
            throw InstallError.notReadable
        }
        // a Web Store package keeps its store id, so `runtime.id` matches what
        // the extension and the sites it talks to expect
        let storeID = source.pathExtension.lowercased() == "crx"
            ? (try? FileHandle(forReadingFrom: source).read(upToCount: 64 * 1024))
                .flatMap(webStoreID(ofCRX:)) : nil
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
                let data = try Data(contentsOf: source)
                let kind = source.pathExtension.lowercased()
                let zip = kind == "crx" ? try stripCRXHeader(data) : data
                let archive = dest.appendingPathComponent("extension.zip")
                try zip.write(to: archive)
                if let origin = kind == "crx" ? webStoreID(ofCRX: data) : (kind == "xpi" ? "xpi" : nil) {
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

    /// sidecar beside a stored package: the Web Store id of a CRX, or `xpi` for a
    /// Firefox package. read when deriving the identity redirect host
    static let packageOriginFile = "package-origin"

    /// the Web Store id signed into a CRX3 header (`SignedData.crx_id`, 16 bytes
    /// spelled as a–p nibbles); nil for CRX2 or a malformed header
    static func webStoreID(ofCRX data: Data) -> String? {
        let bytes = [UInt8](data.prefix(64 * 1024))
        guard bytes.count > 12, bytes.starts(with: Array("Cr24".utf8)), bytes[4] == 3 else {
            return nil
        }
        let length = (8..<12).reduce(0) { $0 | Int(bytes[$1]) << (8 * ($1 - 8)) }
        guard 12 + length <= bytes.count,
            let signed = protobufBytes(field: 10000, in: bytes[12..<(12 + length)]),
            let id = protobufBytes(field: 1, in: signed), id.count == 16
        else { return nil }
        let letters = Array("abcdefghijklmnop")
        return String(id.flatMap { [letters[Int($0 >> 4)], letters[Int($0 & 15)]] })
    }

    /// the first length-delimited value of `field` in a protobuf message
    private static func protobufBytes(field: Int, in message: ArraySlice<UInt8>) -> ArraySlice<UInt8>? {
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
            case 0: guard varint() != nil else { return nil }
            case 1: index += 8
            case 5: index += 4
            case 2:
                guard let length = varint(), length <= message.endIndex - index else { return nil }
                if key >> 3 == field { return message[index..<(index + length)] }
                index += length
            default: return nil
            }
        }
        return nil
    }

    /// a `.crx` is a zip behind a CRX2 or CRX3 header; the zip starts at the first
    /// local-file signature (`PK\x03\x04`)
    private static func stripCRXHeader(_ data: Data) throws -> Data {
        guard let range = data.range(of: Data([0x50, 0x4B, 0x03, 0x04])) else { throw InstallError.notReadable }
        return data.subdata(in: range.lowerBound..<data.endIndex)
    }
}
