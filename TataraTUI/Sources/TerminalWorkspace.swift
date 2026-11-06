// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ArgumentParser
import ComposableArchitecture
import Foundation
import Observation
import TataraCore
import TataraGitHub
import TataraKit
import TataraPersistence
import TataraSystem
import TermLoom
import TermLoomTextArea

// MARK: - TataraCommand

@main
struct TataraCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tatara",
    abstract: "A structural code review workspace for your terminal.",
    version: TataraVersion.current,
  )

  @Option(name: .shortAndLong, help: "Repository in OWNER/REPO format.")
  var repo: String?
  @Option(help: "GitHub hostname, including GitHub Enterprise.")
  var host: String?
  @Option(help: "Catppuccin flavor: latte, frappe, macchiato, mocha.")
  var theme: String?
  @Option(help: "Language: en, ko, ja, zh-Hans, zh-Hant.")
  var language: String?
  @Option(help: "Path to config.toml.")
  var config: String?
  @Option(help: "Files pane layout: tree or list.")
  var filesView: String?
  @Option(help: "Preferred PR and Files pane width in columns (minimum 24).")
  var sidebarWidth: Int?
  @Option(help: "Wrap diff lines: on or off (toggle with w).")
  var wrap: String?
  @Flag(help: "Open the pull request associated with the current directory's Git branch.")
  var current = false
  @Flag(help: "Explore synthetic review data without a GitHub account.")
  var demo = false

  @Flag(help: "Enable color even when NO_COLOR is set.")
  var forceColor = false
  @Flag(help: "Disable color output. Also honors NO_COLOR.")
  var noColor = false
  @Flag(help: "Use ASCII decorations while preserving source text.")
  var ascii = false
  @Flag(help: "Follow pane focus with the terminal cursor; no animated motion.")
  var accessible = false
  @Flag(help: "Follow pane focus with the terminal cursor.")
  var cursorFollowsFocus = false
  @Flag(help: "Keep loading artwork still and suppress motion.")
  var reduceMotion = false
  @Flag(help: "Keep loading artwork still for stable captures.")
  var stableOutput = false

  mutating func validate() throws {
    if current, repo != nil {
      throw ValidationError("--current uses the repository in the current directory; omit --repo.")
    }
  }

  mutating func run() async throws {
    let workspace = try await TerminalWorkspace(options: self)
    try await workspace.start()
  }
}

// MARK: - TerminalWorkspace

@MainActor @Observable
final class TerminalWorkspace: TerminalApplication, PeriodicallyRedrawingTerminalApplication {

  // MARK: Lifecycle

  init(options: TataraCommand) throws {
    self.options = options
    var backend = ANSIBackend()
    size = try backend.size()
  }

  // MARK: Internal

  // Wheel updates use source-owned offsets and do not depend on refreshed widget hit testing.
  let coalescesScrollPresentation = true
  let options: TataraCommand
  var store: StoreOf<WorkspaceFeature>?
  var failure: String?
  var bootstrapPreferences = Preferences()
  var size: Size
  var focusedControl: ControlID?
  var fields = [String: TextFieldState]()
  var editors = [String: TextAreaState]()
  var editorTexts = [String: String]()
  var reviewScroll = 0
  var commentScroll = 0
  var reviewPreview: ReviewDocument?
  @ObservationIgnored var previewTask: Task<Void, Never>?
  @ObservationIgnored var previewGeneration = 0

  var needsPeriodicRedraw: Bool {
    guard !options.reduceMotion, !options.stableOutput, !options.accessible, failure == nil else { return false }
    return store.map(ForgeLoading.isActive) ?? true
  }

  var loadingFrame: Int {
    needsPeriodicRedraw ? ForgeLoading.frame(elapsed: ProcessInfo.processInfo.systemUptime - loadingOrigin) : 0
  }

  var body: TerminalScreen {
    guard let store else {
      var screen = TerminalScreen(ascii: options.ascii)
      if let failure {
        screen.text(failure, in: Rect(origin: .init(x: 1, y: 1), size: size))
      } else {
        ForgeLoading.draw(
          in: Rect(size: size),
          message: Localization(language: bootstrapPreferences.language)("Loading…"),
          frame: loadingFrame,
          ascii: options.ascii,
          palette: Palette(
            bootstrapPreferences.theme,
            noColor: options.noColor || (!options.forceColor && ProcessInfo.processInfo.environment["NO_COLOR"] != nil),
          ),
          brand: true,
          into: &screen,
        )
      }
      return screen
    }
    return WorkspacePresentation(
      store: store,
      size: size,
      demo: options.demo,
      fields: fields,
      editors: editors,
      editorTexts: editorTexts,
      reviewScroll: reviewScroll,
      reviewPreview: reviewPreview,
      commentScroll: commentScroll,
      failure: failure,
      noColor: options
        .noColor || (!options.forceColor && ProcessInfo.processInfo.environment["NO_COLOR"] != nil),
      ascii: options.ascii,
      cursorFollowsFocus: options.accessible || options.cursorFollowsFocus,
      palette: Palette(
        store.preferences.theme,
        noColor: options.noColor || (!options.forceColor && ProcessInfo.processInfo.environment["NO_COLOR"] != nil),
      ),
      loadingFrame: loadingFrame,
    )
    .screen()
  }

  var geometry: WorkspaceGeometry {
    .init(
      size: size,
      preferredSidebarWidth: store?.preferences.sidebarWidth ?? Preferences.defaultSidebarWidth,
      isSelectingItems: store?.isSelectingItems ?? true,
    )
  }

  var usesInlineReview: Bool {
    store?.reviewLocation != nil && geometry.canShowInlineReview
  }

  var reviewPreviewHeight: Int {
    usesInlineReview ? max(1, (store?.reviewPanelHeight ?? 9) - 7) : max(1, size.height - 14)
  }

  var reviewCommentCapacity: Int {
    if !usesInlineReview {
      geometry.reviewCommentCapacity
    } else {
      max(
        0,
        min(3, (store?.reviewPanelHeight ?? 9) - 11),
      )
    }
  }

  static func keyName(_ event: KeyEvent) -> String {
    switch event.key {
    case .character(let value):
      if event.modifiers.contains(.control) {
        return "ctrl-\(String(value).lowercased())"
      }
      if value == " " {
        return "space"
      }
      return event.modifiers.contains(.shift) && value.isLetter ? String(value).uppercased() : String(value)

    case .enter: return "enter"

    case .escape: return "esc"

    case .tab: return event.modifiers.contains(.shift) ? "shift-tab" : "tab"

    case .up: return "up"

    case .down: return "down"

    case .left: return "left"

    case .right: return "right"

    case .backspace: return "backspace"

    case .home: return "home"

    case .end: return "end"

    case .pageDown: return "page-down"

    case .pageUp: return "page-up"

    default: return ""
    }
  }

  func start() async throws {
    let bootstrap = Task { await self.bootstrap() }
    defer { bootstrap.cancel()
      appearance?.cancel()
      previewTask?.cancel()
      store = nil
    }
    try await run(viewport: .fullscreen, capturesMouse: true)
  }

  func updateViewport() {
    guard let store else { return }
    store.send(.viewportChanged(width: geometry.content.width - 2, height: max(1, geometry.content.height - 3)))
    store.send(.popupViewportChanged(width: max(1, geometry.popup.width - 4), height: max(1, geometry.popup.height - 9)))
    store.send(.helpViewportChanged(max(1, geometry.popup.height - 5)))
    store.send(.sidebarViewportChanged(items: max(1, geometry.items.height - 2), files: max(1, geometry.files.height - 2)))
  }

  func update(_ event: TerminalEvent) async -> ApplicationUpdate {
    if case .resize(let size) = event {
      self.size = size
      updateViewport()
      if store?.review?.isConfirming == true {
        prepareReviewPreview()
      }
      return .redraw
    }
    if case .focusChanged(let id) = event {
      focusedControl = id
      return .redraw
    }
    if case .key(let key) = event, key.kind == .release {
      return .ignore
    }
    if case .key(let key) = event, key.key == .character("c"), key.modifiers.contains(.control) {
      return .quit
    }
    guard let store else {
      return event == .key(KeyEvent(.character("q"))) ? .quit : .ignore
    }
    if store.filterEditor != nil || store.review != nil || store.commentEditor != nil {
      return handleEditor(event)
    }
    if let search = store.fileSearch {
      if case .key(let press) = event {
        store.send(.fileSearch(.keyPressed(Self.keyName(press))))
      }
      if case .paste(let text) = event, search.isEditing {
        for character in TerminalText.sanitize(text)
          .replacing("\n", with: " ") { store.send(.fileSearch(.keyPressed(String(character)))) }
      }
      return .redraw
    }
    if case .mouse(let mouse) = event {
      handleMouse(mouse)
      return .redraw
    }
    if case .paste(let text) = event, let picker = store.picker {
      guard picker.isEditing else { return .ignore }
      store.send(.pickerQueryChanged(picker.query + TerminalText.sanitize(text).replacing("\n", with: " ")))
      return .redraw
    }
    if case .paste(let text) = event, store.isSearching {
      for character in TerminalText.sanitize(text) {
        store.send(.keyPressed(String(character)))
      }
      return .redraw
    }
    guard case .key(let press) = event else { return .ignore }
    let key = Self.keyName(press)
    if !store.isSearching, !store.showsHelp, store.picker == nil {
      if store.preferences.keymap.command(for: key) == .quit {
        return .quit
      }
      if
        store.preferences.keymap.command(for: key) == .openBrowser,
        let url = store.focusedCommentKey == nil
        ? store.selectedItem?.url
        : store.focusedCommentKey
          .flatMap({ store.detail?.comment(for: $0)?.url }),
        url.scheme == "https",
        url.host == store.repository.host
      {
        Task { do { try await Self.open(url) } catch { self.failure = String(describing: error) } }
        return .ignore
      }
    }
    let wasSelecting = store.isSelectingItems
    let start = ProcessInfo.processInfo.systemUptime
    store.send(.keyPressed(key))
    if wasSelecting != store.isSelectingItems {
      updateViewport()
    }
    if NavigationTrace.destination != nil {
      let elapsed = ProcessInfo.processInfo.systemUptime - start
      Task { await NavigationTrace.shared.record(start: start, elapsed: elapsed, frameStart: .seconds(start)) }
    }
    return .redraw
  }

  func prepareReviewPreview() {
    previewTask?.cancel()
    previewGeneration += 1
    reviewPreview = nil
    guard let review = store?.review else { return }
    let generation = previewGeneration
    let width = max(1, usesInlineReview ? geometry.content.width - 4 : geometry.review.width - 4)
    let body = review.body
    let comments = review.comments
    let item = review.item.id
    let head = review.expectedHead
    let mergeBase = review.expectedMergeBase
    let event = review.event
    previewTask = Task {
      do {
        let document = try await Self.preparePreview(body: body, comments: comments, width: width)
        try Task.checkCancellation()
        guard
          generation == previewGeneration,
          let current = store?.review,
          current.item.id == item,
          current.expectedHead == head,
          current.expectedMergeBase == mergeBase,
          current.event == event,
          current.isConfirming || current.revisionChanged,
          current.body == body,
          current.comments == comments
        else { return }
        reviewPreview = document
        reviewScroll = min(reviewScroll, max(0, document.lines.count - reviewPreviewHeight))
      } catch is CancellationError {} catch { failure = String(describing: error) }
    }
  }

  // MARK: Private

  @ObservationIgnored private let loadingOrigin = ProcessInfo.processInfo.systemUptime

  @ObservationIgnored private var appearance: StoreTask?

  @concurrent
  private static func preparePreview(
    body: String,
    comments: [InlineComment],
    width: Int,
  ) async throws -> ReviewDocument {
    let text = ([body] + comments.flatMap { comment in
      [
        "\(comment.path):\(comment.startLine.map { String($0) + "–" } ?? "")\(comment.line) · \(comment.side.rawValue)",
        comment.body,
      ]
    }).joined(separator: "\n\n")
    return try await DocumentRenderer.prepare(text, width)
  }

  @concurrent
  private static func open(_ url: URL) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url.absoluteString]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw TataraError(.unavailable, detail: "Could not open the browser.") }
  }

  private func bootstrap() async {
    do {
      try await NavigationTrace.shared.start()
      var preferences = try await Configuration.loadAsync(path: options.config)
      if let value = options.wrap {
        guard value == "on" || value == "off" else { throw TataraError(.configuration, detail: "wrap must be on or off.") }
        preferences.wrap = value == "on"
      }
      if let width = options.sidebarWidth {
        guard width >= 24 else { throw TataraError(.configuration, detail: "sidebar-width must be at least 24 columns.") }
        preferences.sidebarWidth = width
      }
      if let raw = options.filesView {
        guard let value = FilesView(rawValue: raw)
        else { throw TataraError(.configuration, detail: "Unknown files view: \(raw)") }
        preferences.filesView = value
      }
      if let raw = options.theme {
        guard let value = Theme(rawValue: raw) else { throw TataraError(.configuration, detail: "Unknown theme: \(raw)") }
        preferences.theme = value
      }
      if let raw = options.language {
        guard let value = Language(rawValue: raw) else { throw TataraError(.configuration, detail: "Unknown language: \(raw)") }
        preferences.language = value
      }
      bootstrapPreferences = preferences
      let adapter = GitHubAdapter()
      let repository: RepositoryID =
        if options.demo {
          try RepositoryID("PangMo5/Tatara")
        } else if let repo = options.repo {
          try RepositoryID(repo, host: options.host ?? "github.com")
        } else {
          try await adapter.detectRepository(host: options.host)
        }
      let cache: CacheClient
      async let discoveredGit: LocalGitReader = options.demo
        ? .disabled
        : LocalGitReader.discover(repository: repository)
      if options.demo {
        cache = .disabled
      } else {
        let account = try await adapter.accountIdentifier(host: repository.host)
        let storage = try await PersistentCache.bootstrapDatabase()
        cache = storage.client.scoped(to: "\(repository.forge.rawValue):\(repository.host):\(account)")
      }
      let localGit = try await discoveredGit
      let forge = options.demo ? DemoData.client(repository) : GitHubAdapter(cache: cache, localGit: localGit).client
      let diff = Difftastic(forge: forge, cache: cache).client
      let presets = try await FilterPresetStore.open()
      try Task.checkCancellation()
      var initialState = WorkspaceFeature.State(
        repository: repository,
        preferences: preferences,
        strings: LocalizedStrings.values[preferences.language.rawValue] ?? [:],
      )
      initialState.isSelectingItems = !options.current
      if options.current {
        let item: ForgeItem
        if options.demo {
          guard let demoItem = try await forge.list(repository, .pullRequest, 1).items.first else { throw TataraError(
            .unavailable,
            detail: "Demo has no PR.",
          ) }
          item = demoItem
        } else {
          item = try await adapter.currentPullRequest(repository)
        }
        initialState.initialItem = item
      }
      let workspace = Store(initialState: initialState) { WorkspaceFeature() } withDependencies: {
        $0[ForgeClient.self] = forge
        $0[DiffClient.self] = diff
        $0[DocumentClient.self] = DocumentRenderer.client
        $0[FilterPresetClient.self] = presets.client
        $0[ClipboardClient.self] = .init(copy: { text in _ = try await CommandRunner.live.checked("pbcopy", [], input: text) })
      }
      store = workspace
      updateViewport()
      appearance = workspace.send(.appeared)
    } catch is CancellationError {
    } catch {
      guard !Task.isCancelled else { return }
      failure = Localization(language: Language(rawValue: options.language ?? "") ?? .english).error(.wrapping(error))
    }
  }

}
