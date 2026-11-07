import Foundation

/// Presentation and request-boundary checks; persisted historical responses stay decodable.
public enum CoachReplyText {
  public static func claimsUncommittedWrite(_ text: String) -> Bool {
    let pattern = #"(?:^|[。！？\n])\s*(?:好的[，,。]?\s*)?(?:我)?(?:已经|已)?(?:帮你|为你)?(?:已经|已)?(?:记住了|记下了|保存了|修改好了|记录好了|更新好了|已记住(?!的)|已保存(?!的)|已记录(?!的)|已修改|已更新|已录入)"#
    return text.range(of: pattern, options: .regularExpression) != nil
  }
  public static func body(_ turn: CoachTurn) -> String {
    // Only the App writes outcome. An old model claim with no transaction is not a receipt.
    if claimsUncommittedWrite(turn.reply), turn.outcome == nil {
      return "这条回复没有对应的保存结果，内容尚未保存。"
    }
    if !(turn.agentOperationIDs ?? []).isEmpty,
      turn.origin == "本机结果" || ["已记住。", "请核对这条记忆。"].contains(turn.reply) { return "" }
    var text = turn.reply
    for source in turn.exchange?.response.sources ?? [] where source.valid {
      text = text.replacingOccurrences(of: "[" + source.id + "]", with: "[" + source.id + "](<" + source.url + ">)")
    }
    return text
  }
  public static func questions(_ turn: CoachTurn) -> [String] {
    func normalized(_ value: String) -> String {
      value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    let body = normalized(body(turn))
    var seen = Set<String>()
    return (turn.exchange?.response.questions ?? []).filter {
      let key = normalized($0)
      return !key.isEmpty && !body.contains(key) && seen.insert(key).inserted
    }
  }
  public static func cards(_ turn: CoachTurn) -> [CoachResponseCard] {
    // Navigation-only reasons are not additional assistant replies.
    (turn.exchange?.response.cards ?? []).filter { $0.candidate_id != nil }
  }
  public static func copy(_ turn: CoachTurn, data: AppData) -> String {
    let operations = (turn.agentOperationIDs ?? []).compactMap { id in
      data.personalAgent?.operations.first { $0.id == id }
    }
    let results = operations.map { op in
      data.personalAgent?.receipts.first { $0.id == op.id }?.summary ?? op.summary
    }
    let sourceLinks = (turn.exchange?.response.sources ?? []).map { "\($0.id) · \($0.title)：\($0.url)" }
    return ([body(turn)] + questions(turn) + cards(turn).map(\.detail) + results + sourceLinks).filter { !$0.isEmpty }.joined(separator: "\n\n")
  }
}
