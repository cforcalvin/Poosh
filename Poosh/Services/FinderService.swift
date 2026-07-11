import AppKit
import Foundation
import os

enum FinderNavigationDirection {
  case left
  case right
  case up
  case down
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
        return "Poosh needs permission to control Finder. Open System Settings → Privacy & Security → Automation and enable Poosh for Finder."
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

  static func selectItem(at url: URL) -> Result<Void, SelectionError> {
    let escapedPath = escapedPOSIXPath(url.path)
    let script = """
      tell application "Finder"
          set targetItem to POSIX file "\(escapedPath)" as alias
          select targetItem
          reveal targetItem
          return "ok"
      end tell
      """
    return runScript(script).map { _ in () }
  }

  static func spatialNeighbor(
    of url: URL,
    direction: FinderNavigationDirection
  ) -> Result<URL, SelectionError> {
    switch containerItems(for: url) {
    case .failure(let error):
      return .failure(error)
    case .success(let layout):
      let images = layout.items.filter { ImageFormatValidator.isSupportedImage(url: $0.url) }
      let currentPath = url.standardizedFileURL.path
      guard let currentIndex = images.firstIndex(where: {
        $0.url.standardizedFileURL.path == currentPath
      }) else {
        return .failure(.noSelection)
      }

      let neighbor: URL?
      if layout.usesSpatialNavigation {
        neighbor = spatialNeighbor(
          among: images,
          current: images[currentIndex],
          direction: direction
        )
      } else {
        neighbor = linearNeighbor(
          among: images,
          currentIndex: currentIndex,
          direction: direction
        )
      }

      guard let neighbor else { return .failure(.noNeighbor) }
      return .success(neighbor)
    }
  }

  private struct ContainerLayout {
    let items: [FinderSpatialItem]
    let usesSpatialNavigation: Bool
  }

  private static func containerItems(for url: URL) -> Result<ContainerLayout, SelectionError> {
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

  private static func linearNeighbor(
    among images: [FinderSpatialItem],
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
    guard images.indices.contains(newIndex) else { return nil }
    return images[newIndex].url
  }

  private static func spatialNeighbor(
    among images: [FinderSpatialItem],
    current: FinderSpatialItem,
    direction: FinderNavigationDirection
  ) -> URL? {
    let candidates: [FinderSpatialItem]

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
