import Foundation
import CryptoKit

struct EditRecipe: Codable, Equatable {
  struct Point: Codable, Equatable {
    var x: Double
    var y: Double
  }

  /// Normalized crop in displayed (post-rotation) image space, origin top-left.
  struct CropRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = CropRect(x: 0, y: 0, width: 1, height: 1)

    var isIdentity: Bool {
      abs(x) < 0.002 && abs(y) < 0.002
        && abs(width - 1) < 0.002 && abs(height - 1) < 0.002
    }

    func clamped() -> CropRect {
      let x = min(max(self.x, 0), 1)
      let y = min(max(self.y, 0), 1)
      let width = min(max(self.width, 0.02), 1 - x)
      let height = min(max(self.height, 0.02), 1 - y)
      return CropRect(x: x, y: y, width: width, height: height)
    }
  }

  var curvePoints: [Point]
  var rotationQuarterTurns: Int
  var cropRect: CropRect?
  /// Fine straighten angle in degrees (−45…45), applied after quarter turns.
  var straightenDegrees: Double
  var isBlackAndWhite: Bool
  /// Center of the soft hue band in degrees (0…360). `nil` = no hue edit.
  var hueCenterDegrees: Double?
  /// Hue shift applied to the soft band around `hueCenterDegrees` (−180…180).
  var hueShiftDegrees: Double
  /// Saturation change for the soft band (−1…1). 0 = unchanged; −1 desaturates; +1 boosts.
  var hueSaturationAmount: Double
  var sourcePath: String
  var fingerprint: String
  var bookmarkData: Data?

  /// Soft hue-band half-width used by the processor (±degrees), with feathered edges.
  static let hueBandHalfWidthDegrees: Double = 35
  /// Inner full-strength core as a fraction of `hueBandHalfWidthDegrees` (rest is feather).
  static let hueBandCoreFraction: Double = 0.35

  var hasActiveHueShift: Bool {
    guard hueCenterDegrees != nil else { return false }
    return abs(hueShiftDegrees) > 0.5 || abs(hueSaturationAmount) > 0.01
  }

  enum CodingKeys: String, CodingKey {
    case curvePoints
    case rotationQuarterTurns
    case cropRect
    case straightenDegrees
    case isBlackAndWhite
    case hueCenterDegrees
    case hueShiftDegrees
    case hueSaturationAmount
    case sourcePath
    case fingerprint
    case bookmarkData
  }

  init(
    curvePoints: [Point],
    rotationQuarterTurns: Int,
    cropRect: CropRect?,
    straightenDegrees: Double = 0,
    isBlackAndWhite: Bool = false,
    hueCenterDegrees: Double? = nil,
    hueShiftDegrees: Double = 0,
    hueSaturationAmount: Double = 0,
    sourcePath: String,
    fingerprint: String,
    bookmarkData: Data?
  ) {
    self.curvePoints = curvePoints
    self.rotationQuarterTurns = rotationQuarterTurns
    self.cropRect = cropRect
    self.straightenDegrees = straightenDegrees
    self.isBlackAndWhite = isBlackAndWhite
    self.hueCenterDegrees = hueCenterDegrees
    self.hueShiftDegrees = hueShiftDegrees
    self.hueSaturationAmount = hueSaturationAmount
    self.sourcePath = sourcePath
    self.fingerprint = fingerprint
    self.bookmarkData = bookmarkData
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    curvePoints = try c.decode([Point].self, forKey: .curvePoints)
    rotationQuarterTurns = try c.decode(Int.self, forKey: .rotationQuarterTurns)
    cropRect = try c.decodeIfPresent(CropRect.self, forKey: .cropRect)
    straightenDegrees = try c.decodeIfPresent(Double.self, forKey: .straightenDegrees) ?? 0
    isBlackAndWhite = try c.decodeIfPresent(Bool.self, forKey: .isBlackAndWhite) ?? false
    hueCenterDegrees = try c.decodeIfPresent(Double.self, forKey: .hueCenterDegrees)
    hueShiftDegrees = try c.decodeIfPresent(Double.self, forKey: .hueShiftDegrees) ?? 0
    hueSaturationAmount = try c.decodeIfPresent(Double.self, forKey: .hueSaturationAmount) ?? 0
    sourcePath = try c.decode(String.self, forKey: .sourcePath)
    fingerprint = try c.decode(String.self, forKey: .fingerprint)
    bookmarkData = try c.decodeIfPresent(Data.self, forKey: .bookmarkData)
  }

  static func identity(sourcePath: String, fingerprint: String, bookmarkData: Data?) -> EditRecipe {
    EditRecipe(
      curvePoints: [Point(x: 0, y: 0), Point(x: 1, y: 1)],
      rotationQuarterTurns: 0,
      cropRect: nil,
      straightenDegrees: 0,
      isBlackAndWhite: false,
      hueCenterDegrees: nil,
      hueShiftDegrees: 0,
      hueSaturationAmount: 0,
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
