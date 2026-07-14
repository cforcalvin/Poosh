import AppKit
import Foundation
import os

enum FinderNavigationDirection {
  case left
  case right
  case up
  case down
}

struct FinderBrowseItem {
  let url: URL
  let x: Double
  let y: Double
}

/// Snapshot of a Finder folder used for arrow-key browsing without AppleScript per keypress.
struct FinderBrowseLayout {
  let items: [FinderBrowseItem]
  let usesSpatialNavigation: Bool

  func contains(_ url: URL) -> Bool {
    let path = url.standardizedFileURL.path
    return items.contains { $0.url.standardizedFileURL.path == path }
  }

  func neighbor(of url: URL, direction: FinderNavigationDirection) -> URL? {
    let path = url.standardizedFileURL.path
    guard let currentIndex = items.firstIndex(where: {
      $0.url.standardizedFileURL.path == path
    }) else { return nil }

    if usesSpatialNavigation {
      return FinderService.spatialNeighbor(
        among: items,
        current: items[currentIndex],
        direction: direction
      )
    }
    return FinderService.linearNeighbor(
      among: items,
      currentIndex: currentIndex,
      direction: direction
    )
  }
}

private struct FinderSpatialItem {
  let url: URL
  let x: Double
  let y: Double
}

enum FinderService {
  private static let logger = Logger(subsystem: "com.poosh.Poosh", category: "Finder")

  enum SelectionError: Error, LocalizedError {
    case automationDenied
    case scriptFailed(String)
    case noSelection
    case noNeighbor

    var errorDescription: String? {
      switch self {
      case .automationDenied:
        return "Poosh needs permission to control Finder. When the system dialog appears, click OK. Then open System Settings → Privacy & Security → Automation and enable Poosh → Finder."
      case .scriptFailed(let message):
        return "Finder script failed: \(message)"
      case .noSelection:
        return "No file is selected in Finder. Select an image in Finder, then try again."
      case .noNeighbor:
        return "No image in that direction."
      }
    }
  }

  private static let selectedPathScript = """
    tell application "Finder"
        set selectedItems to selection as alias list
        if (count of selectedItems) > 0 then
            return POSIX path of (item 1 of selectedItems)
        end if
    end tell
    """

  static func selectedFileURL() -> Result<URL, SelectionError> {
    runScript(selectedPathScript).map { URL(fileURLWithPath: $0) }
  }

  static func activateFinder() -> Result<Void, SelectionError> {
    runScript("""
      tell application "Finder" to activate
      return "ok"
      """).map { _ in () }
  }

  static func selectItem(at url: URL, reveal: Bool = true) -> Result<Void, SelectionError> {
    let escapedPath = escapedPOSIXPath(url.path)
    let revealLine = reveal ? "reveal targetItem" : ""
    let script = """
      tell application "Finder"
          set targetItem to POSIX file "\(escapedPath)" as alias
          select targetItem
          \(revealLine)
          return "ok"
      end tell
      """
    return runScript(script).map { _ in () }
  }

  static func spatialNeighbor(
    of url: URL,
    direction: FinderNavigationDirection
  ) -> Result<URL, SelectionError> {
    switch browseLayout(around: url) {
    case .failure(let error):
      return .failure(error)
    case .success(let layout):
      guard let neighbor = layout.neighbor(of: url, direction: direction) else {
        return .failure(.noNeighbor)
      }
      return .success(neighbor)
    }
  }

  /// Instant folder index using the filesystem — no AppleScript, no per-file metadata.
  /// Sort order matches Finder's list-style browsing (localized filename).
  static func browseLayoutFromDisk(around url: URL) -> FinderBrowseLayout {
    let folder = url.deletingLastPathComponent()
    // Do not request resourceValues — on iCloud folders that stalls for seconds.
    let contents = (try? FileManager.default.contentsOfDirectory(
      at: folder,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )) ?? []

    let previewable = contents
      .filter { ImageFormatValidator.isBrowsablePreview(url: $0) }
      .sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
      }

    let items = previewable.enumerated().map { index, fileURL in
      FinderBrowseItem(url: fileURL, x: 0, y: Double(index))
    }
    return FinderBrowseLayout(items: items, usesSpatialNavigation: false)
  }

  /// Loads (or returns cached) previewable items via Finder AppleScript — slow; avoid on open/arrows.
  static func browseLayout(around url: URL) -> Result<FinderBrowseLayout, SelectionError> {
    switch containerItems(for: url) {
    case .failure(let error):
      return .failure(error)
    case .success(let layout):
      let items = layout.items.map {
        FinderBrowseItem(url: $0.url, x: $0.x, y: $0.y)
      }
      return .success(FinderBrowseLayout(
        items: items,
        usesSpatialNavigation: layout.usesSpatialNavigation
      ))
    }
  }

  static func linearNeighbor(
    among items: [FinderBrowseItem],
    currentIndex: Int,
    direction: FinderNavigationDirection
  ) -> URL? {
    let offset: Int
    switch direction {
    case .left, .up:
      offset = -1
    case .right, .down:
      offset = 1
    }

    let newIndex = currentIndex + offset
    guard items.indices.contains(newIndex) else { return nil }
    return items[newIndex].url
  }

  static func spatialNeighbor(
    among images: [FinderBrowseItem],
    current: FinderBrowseItem,
    direction: FinderNavigationDirection
  ) -> URL? {
    let candidates: [FinderBrowseItem]

    switch direction {
    case .right:
      candidates = images.filter { $0.x > current.x }
      return candidates.min {
        abs($0.y - current.y) * 2 + ($0.x - current.x) < abs($1.y - current.y) * 2 + ($1.x - current.x)
      }?.url
    case .left:
      candidates = images.filter { $0.x < current.x }
      return candidates.min {
        abs($0.y - current.y) * 2 + (current.x - $0.x) < abs($1.y - current.y) * 2 + (current.x - $1.x)
      }?.url
    case .down:
      candidates = images.filter { $0.y > current.y }
      return candidates.min {
        abs($0.x - current.x) * 2 + ($0.y - current.y) < abs($1.x - current.x) * 2 + ($1.y - current.y)
      }?.url
    case .up:
      candidates = images.filter { $0.y < current.y }
      return candidates.min {
        abs($0.x - current.x) * 2 + (current.y - $0.y) < abs($1.x - current.x) * 2 + (current.y - $1.y)
      }?.url
    }
  }

  private struct ContainerLayout {
    let items: [FinderSpatialItem]
    let usesSpatialNavigation: Bool
  }

  private static var neighborCache: (containerPath: String, layout: ContainerLayout, timestamp: Date)?

  private static func containerItems(for url: URL) -> Result<ContainerLayout, SelectionError> {
    let containerPath = url.deletingLastPathComponent().standardizedFileURL.path
    if let cached = neighborCache,
       cached.containerPath == containerPath,
       Date().timeIntervalSince(cached.timestamp) < 30.0 {
      return .success(cached.layout)
    }

    let result = fetchContainerItems(for: url)
    if case .success(let layout) = result {
      // Filter once when caching — extension-only browse check (no iCloud metadata).
      let previewable = layout.items.filter { ImageFormatValidator.isBrowsablePreview(url: $0.url) }
      let filtered = ContainerLayout(items: previewable, usesSpatialNavigation: layout.usesSpatialNavigation)
      neighborCache = (containerPath, filtered, Date())
      return .success(filtered)
    }
    return result
  }

  private static func fetchContainerItems(for url: URL) -> Result<ContainerLayout, SelectionError> {
    let escapedPath = escapedPOSIXPath(url.path)
    let script = """
      tell application "Finder"
          set theItem to POSIX file "\(escapedPath)" as alias
          set itemContainer to container of theItem
          set viewStyle to "list view"

          if itemContainer is desktop then
              set itemsList to every item of desktop
              try
                  set viewStyle to current view of container window
              end try
          else
              set itemsList to every item of itemContainer
              try
                  set viewStyle to current view of container window of itemContainer
              end try
          end if

          set output to "VIEW:" & viewStyle & linefeed
          repeat with anItem in itemsList
              try
                  set itemPath to POSIX path of (anItem as alias)
                  if viewStyle is "icon view" or viewStyle is "flow view" then
                      set itemPos to position of anItem
                      set output to output & itemPath & tab & (item 1 of itemPos) & tab & (item 2 of itemPos) & linefeed
                  else
                      set output to output & itemPath & linefeed
                  end if
              end try
          end repeat
          return output
      end tell
      """

    return runScript(script).flatMap { text in
      parseContainerLayout(text)
    }
  }

  private static func parseContainerLayout(_ text: String) -> Result<ContainerLayout, SelectionError> {
    let lines = text
      .split(separator: "\n")
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    guard let firstLine = lines.first, firstLine.hasPrefix("VIEW:") else {
      return .failure(.scriptFailed("Unexpected Finder layout response"))
    }

    let viewStyle = String(firstLine.dropFirst("VIEW:".count))
    let usesSpatialNavigation = viewStyle == "icon view" || viewStyle == "flow view"
    var items: [FinderSpatialItem] = []

    for line in lines.dropFirst() {
      if usesSpatialNavigation {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let x = Double(parts[parts.count - 2]),
              let y = Double(parts[parts.count - 1]) else {
          continue
        }
        let path = parts.dropLast(2).joined(separator: "\t")
        items.append(FinderSpatialItem(url: URL(fileURLWithPath: path), x: x, y: y))
      } else {
        items.append(FinderSpatialItem(url: URL(fileURLWithPath: line), x: 0, y: 0))
      }
    }

    guard !items.isEmpty else { return .failure(.noSelection) }
    return .success(ContainerLayout(items: items, usesSpatialNavigation: usesSpatialNavigation))
  }

  private static func escapedPOSIXPath(_ path: String) -> String {
    path
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }

  private static func runScript(_ source: String) -> Result<String, SelectionError> {
    if Thread.isMainThread {
      return executeScript(source)
    }
    return DispatchQueue.main.sync {
      executeScript(source)
    }
  }

  private static func executeScript(_ source: String) -> Result<String, SelectionError> {
    guard let script = NSAppleScript(source: source) else {
      return .failure(.scriptFailed("Could not compile AppleScript"))
    }

    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)

    if let error {
      let code = error[NSAppleScript.errorNumber] as? Int ?? 0
      let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
      logger.error("AppleScript error \(code): \(message, privacy: .public)")

      if code == -1743 || message.localizedCaseInsensitiveContains("not authorized") {
        return .failure(.automationDenied)
      }
      return .failure(.scriptFailed(message))
    }

    guard let text = path(from: result), !text.isEmpty else {
      return .failure(.noSelection)
    }

    return .success(text)
  }

  private static func path(from descriptor: NSAppleEventDescriptor) -> String? {
    if let value = descriptor.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
      return value
    }

    if let value = descriptor.coerce(toDescriptorType: typeUTF8Text)?.stringValue?
      .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
      return value
    }

    if let value = descriptor.coerce(toDescriptorType: typeUnicodeText)?.stringValue?
      .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
      return value
    }

    return nil
  }
}
