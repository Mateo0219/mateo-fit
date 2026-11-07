import FitnessCore
import SwiftUI

// Only the input view observes keystrokes. The conversation and full record file
// are updated after a pause, or explicitly before send/navigation/background.
@MainActor final class CoachComposerDraft: ObservableObject {
  @Published private(set) var editorRevision = 0
  // Native text/IME callbacks may arrive after send or restore. A binding belongs
  // to one editor lifetime; it cannot write into the next draft.
  var editorText: Binding<String> {
    let revision = editorRevision
    return Binding(get: { self.text }, set: { [weak self] value in
      guard let self, self.editorRevision == revision else { return }
      self.text = value
    })
  }
  @Published var text = "" { didSet { scheduleSave() } }
  @Published var photo: Data? { didSet { scheduleSave() } }
  private var save: ((String, Data?, String) -> Bool)?
  private var pending: Task<Void, Never>?
  private let delay: UInt64
  private var restoring = false
  init(delayNanoseconds: UInt64 = 600_000_000) { delay = delayNanoseconds }
  func restore(_ draft: HomeComposerDraft?, save: @escaping (String, Data?, String) -> Bool) {
    pending?.cancel(); restoring = true; editorRevision += 1
    text = draft?.text ?? ""; photo = draft?.photo
    self.save = save; restoring = false
  }
  private func scheduleSave() {
    guard !restoring, save != nil else { return }
    pending?.cancel()
    pending = Task { @MainActor [weak self, delay] in
      do { try await Task.sleep(nanoseconds: delay) } catch { return }
      guard let self, !Task.isCancelled else { return }
      _ = self.flush()
    }
  }
  @discardableResult func flush(state: String = "editing") -> Bool {
    pending?.cancel(); pending = nil
    return save?(text, photo, state) ?? false
  }
  @discardableResult func submit(accept: (String, Data?) -> Bool) -> Bool {
    let submittedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard submittedText.count <= 3000, !submittedText.isEmpty || photo != nil,
      accept(submittedText, photo) else { return false }
    pending?.cancel(); pending = nil; restoring = true; editorRevision += 1
    text = ""; photo = nil; restoring = false
    return true
  }
  func cancelPendingSave() { pending?.cancel(); pending = nil }
}

