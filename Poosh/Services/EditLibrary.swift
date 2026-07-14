import Foundation
import CryptoKit

struct EditRecipe: Codable, Equatable {
  struct Point: Codable, Equatable {
    var x: Double
    var y: Double
  }

  var curvePoints: [Point]
  var rotationQuarterTurns: Int
  var sourcePath: String
  var fingerprint: String
  var bookmarkData: Data?

  static func identity(sourcePath: String, fingerprint: String, bookmarkData: Data?) -> EditRecipe {
    EditRecipe(
      curvePoints: [Point(x: 0, y: 0), Point(x: 1, y: 1)],
      rotationQuarterTurns: 0,
      sourcePath: sourcePath,
      fingerprint: fingerprint,
      bookmarkData: bookmarkData
    )
  }
}

struct EditLibraryEntry {
  let id: String
  let directoryURL: URL
  let originalURL: URL
  var recipe: EditRecipe
}

enum EditLibrary {
  private static let folderName = "Edits"
  private static let indexFileName = "index.json"
  private static let recipeFileName = "recipe.json"

  private struct Index: Codable {
    var pathToEntryID: [String: String]
    var fingerprintToEntryID: [String: String]
  }

  private static let queue = DispatchQueue(label: "com.poosh.EditLibrary")
  private static var cachedIndex: Index?

  private static var rootURL: URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return appSupport.appendingPathComponent("Poosh", isDirectory: true)
      .appendingPathComponent(folderName, isDirectory: true)
  }

  private static var indexURL: URL {
    rootURL.appendingPathComponent(indexFileName)
  }

  /// Browse/arrow hot path — path lookup only. Never calls `resourceValues`
  /// (fingerprint), which stalls for seconds on iCloud files.
  static func entry(for sourceURL: URL) -> EditLibraryEntry? {
    entry(for: sourceURL, allowFingerprintLookup: false)
  }

  /// Full lookup including size/mtime fingerprint — use once on first open, not per arrow.
  static func entryResolvingFingerprint(for sourceURL: URL) -> EditLibraryEntry? {
    entry(for: sourceURL, allowFingerprintLookup: true)
  }

  private static func entry(for sourceURL: URL, allowFingerprintLookup: Bool) -> EditLibraryEntry? {
    queue.sync {
      ensureRoot()
      let index = cachedIndex ?? loadIndex()
      cachedIndex = index

      let standardized = sourceURL.standardizedFileURL.path
      if let id = index.pathToEntryID[standardized], let entry = loadEntry(id: id) {
        return entry
      }

      // Symlink-resolved path may differ; only do this when fingerprints are allowed
      // (first open) — resolving can hit the network.
      if allowFingerprintLookup {
        let resolved = normalizedPath(sourceURL)
        if resolved != standardized,
           let id = index.pathToEntryID[resolved],
           let entry = loadEntry(id: id) {
          return entry
        }

        if let fingerprint = fileFingerprint(sourceURL),
           let id = index.fingerprintToEntryID[fingerprint],
           let entry = loadEntry(id: id) {
          return entry
        }
      }

      return nil
    }
  }

  /// Copies the current Finder file as the immutable original and writes the recipe.
  static func save(
    sourceURL: URL,
    recipe: EditRecipe,
    existing: EditLibraryEntry?
  ) throws -> EditLibraryEntry {
    try queue.sync {
      ensureRoot()
      var index = loadIndex()

      let id = existing?.id ?? makeEntryID(for: sourceURL)
      let directory = rootURL.appendingPathComponent(id, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

      let originalExt = sourceURL.pathExtension.isEmpty ? "bin" : sourceURL.pathExtension
      let originalURL = directory.appendingPathComponent("original").appendingPathExtension(originalExt)

      // First successful save: copy Finder bytes as immutable original (call before bake).
      if !FileManager.default.fileExists(atPath: originalURL.path) {
        try FileManager.default.copyItem(at: sourceURL, to: originalURL)
      }

      var recipeToSave = recipe
      recipeToSave.sourcePath = normalizedPath(sourceURL)
      // Keep fingerprint of the immutable original so bake/mtime changes on Finder don't break lookup.
      recipeToSave.fingerprint = existing?.recipe.fingerprint
        ?? fileFingerprint(originalURL)
        ?? recipe.fingerprint
      recipeToSave.bookmarkData = (try? sourceURL.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )) ?? existing?.recipe.bookmarkData

      let recipeURL = directory.appendingPathComponent(recipeFileName)
      let data = try JSONEncoder().encode(recipeToSave)
      try data.write(to: recipeURL, options: .atomic)

      index.pathToEntryID[recipeToSave.sourcePath] = id
      if !recipeToSave.fingerprint.isEmpty {
        index.fingerprintToEntryID[recipeToSave.fingerprint] = id
      }
      try saveIndex(index)
      cachedIndex = index

      return EditLibraryEntry(
        id: id,
        directoryURL: directory,
        originalURL: originalURL,
        recipe: recipeToSave
      )
    }
  }

  private static func loadEntry(id: String) -> EditLibraryEntry? {
    let directory = rootURL.appendingPathComponent(id, isDirectory: true)
    let recipeURL = directory.appendingPathComponent(recipeFileName)
    guard let data = try? Data(contentsOf: recipeURL),
          let recipe = try? JSONDecoder().decode(EditRecipe.self, from: data) else {
      return nil
    }

    let contents = (try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )) ?? []
    guard let originalURL = contents.first(where: { $0.lastPathComponent.hasPrefix("original.") }) else {
      return nil
    }
    guard FileManager.default.fileExists(atPath: originalURL.path) else { return nil }

    return EditLibraryEntry(
      id: id,
      directoryURL: directory,
      originalURL: originalURL,
      recipe: recipe
    )
  }

  private static func entriesOnDisk() -> [(String, URL)] {
    guard let urls = try? FileManager.default.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: [.isDirectoryKey]
    ) else { return [] }
    return urls.compactMap { url in
      var isDir: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
        return nil
      }
      let name = url.lastPathComponent
      guard name != indexFileName else { return nil }
      return (name, url)
    }
  }

  private static func ensureRoot() {
    try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  private static func loadIndex() -> Index {
    guard let data = try? Data(contentsOf: indexURL),
          let index = try? JSONDecoder().decode(Index.self, from: data) else {
      return Index(pathToEntryID: [:], fingerprintToEntryID: [:])
    }
    return index
  }

  private static func saveIndex(_ index: Index) throws {
    let data = try JSONEncoder().encode(index)
    try data.write(to: indexURL, options: .atomic)
  }

  private static func makeEntryID(for url: URL) -> String {
    let path = normalizedPath(url)
    let digest = SHA256.hash(data: Data(path.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func normalizedPath(_ url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.path
  }

  private static func fileFingerprint(_ url: URL) -> String? {
    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
          let size = values.fileSize,
          let modified = values.contentModificationDate else {
      return nil
    }
    return "\(size)-\(modified.timeIntervalSince1970)"
  }
}
