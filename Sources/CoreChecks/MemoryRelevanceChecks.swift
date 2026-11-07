import Foundation
#if DEBUG
@testable import FitnessCore
#else
import FitnessCore
#endif

func runMemoryRelevanceChecks() throws {
  let now = Date()
  func memory(_ content: String, _ topic: String) -> PersonalMemory {
    var m = PersonalMemory(content: content, topic: topic, sourceText: content, sourceTurnID: nil)
    m.createdAt = now.addingTimeInterval(-3600); m.updatedAt = m.createdAt
    return m
  }
  let style = memory("以后回复简短一点", "reply_style")
  let food = memory("我偏好清淡的饭菜", "food_preference")
  let schedule = memory("我周二晚上训练", "training_schedule")
  let allergy = memory("我对花生过敏", "health_constraint")
  let knee = memory("膝盖旧伤，避免深蹲", "health_constraint")
  let general = memory("我喜欢蓝色界面", "general_preference")
  var expired = memory("这周午餐只在公司食堂吃", "temporary"); expired.expiresAt = now.addingTimeInterval(-1)
  var invalid = memory("未经核对的限制", "health_constraint"); invalid.confirmation = "模型推测"
  let forgotten = memory("我不吃香菜", "food_preference")
  var data = AppData(); data.personalAgent = PersonalAgentState()
  data.personalAgent?.memories = [style, food, schedule, allergy, knee, general, expired, invalid, forgotten]
  data.personalAgent?.forgotten = [try JSONDecoder().decode(MemoryTombstone.self, from: JSONSerialization.data(withJSONObject: ["id": forgotten.id.uuidString, "date": now.timeIntervalSinceReferenceDate]))]
  func ids(_ text: String, _ source: AppData = data, enabled: Bool = true) -> Set<String> {
    Set(PersonalAgentContext.build(source, text: text, health: false, memory: enabled, now: now).snapshot.facts.filter { $0.id.hasPrefix("memory.") }.map(\.id))
  }
  func named(_ items: [PersonalMemory]) -> Set<String> { Set(items.map { "memory." + $0.id.uuidString }) }
  check(ids("你支持哪些模型") == named([style]), "Unrelated model-capability questions include only global reply style")
  check(ids("这个健身 App 用的是什么模型") == named([style]), "Fitness words inside a software question do not upload personal fitness memories")
  check(ids("DeepSeek API 如何调用") == named([style]), "API questions do not inherit personal context")
  check(ids("你记忆功能怎么实现") == named([style]), "Memory implementation questions are not permission to recall personal memories")
  let productUsageQuestions = ["训练功能怎么用？", "训练功能如何操作？", "如何使用某个训练功能？", "训练模块怎样打开？", "饮食页面从哪里进入？", "体重记录按钮在哪里？", "记忆功能怎么用？", "我的记忆功能如何查看？",
    "请介绍一下训练模块", "训练功能有什么作用？", "帮我分析训练功能怎么用", "请解释饮食页面", "列出训练模块的能力", "概述训练模块能做什么", "训练功能", "在训练模块里怎么查看我的训练记录？",
    "记忆功能能帮我记录饮食吗？", "训练模块如何帮我安排训练？", "请介绍我的记忆功能", "训练功能如何支持我的训练计划", "给我分析一下训练模块的用途", "帮我看看我的训练页面", "你觉得训练模块的设计怎么样",
    "帮我分析训练模型的代码", "帮我分析训练模型的接口", "帮我分析训练 API", "帮我分析训练软件说明", "帮我分析今天训练模型的代码", "帮我分析我的训练接口", "帮我分析训练模型", "帮我分析训练 SDK", "帮我分析训练算法架构", "帮我分析训练模块中的训练是什么"]
  for question in productUsageQuestions {
    check(ids(question) == named([style]), "Product usage question does not require personal memories: " + question)
  }
  let personalTrainingQuestions = ["我今天训练怎么做？", "今天我的训练如何安排？", "使用训练功能，帮我安排今天练背", "用训练模块帮我安排今天练背", "在训练页面里，我今天训练怎么做", "训练功能怎么用，另外帮我调整今天的训练", "帮我分析今天的训练", "使用训练功能帮我安排今天练背"]
  for question in personalTrainingQuestions {
    check(ids(question) == named([style, schedule, knee]), "Personal training task keeps schedule and safety context: " + question)
  }
  check(ids("使用饮食功能，给我配餐") == named([style, food, allergy]), "A concrete meal-planning request still includes food constraints when it also names a feature")
  let mixedTasks: [(String, [PersonalMemory])] = [
    ("介绍训练模块，给我配餐", [style, food, allergy]),
    ("介绍饮食模块，帮我安排今天练背", [style, schedule, knee]),
    ("介绍饮食模块，给我配餐", [style, food, allergy]),
    ("介绍训练模块，帮我安排今天练背", [style, schedule, knee]),
    ("介绍我的记忆功能，给我配餐", [style, food, allergy]),
    ("介绍我的记忆功能，帮我安排今天练背", [style, schedule, knee]),
    ("给我配餐，介绍训练模块", [style, food, allergy]),
    ("帮我安排今天练背，介绍饮食模块", [style, schedule, knee]),
    ("介绍训练模块并给我配餐", [style, food, allergy]),
    ("给我配餐并介绍训练模块", [style, food, allergy]),
    ("训练模块有什么作用？另外给我配餐", [style, food, allergy]),
    ("介绍训练模块，帮我安排今天练背，给我配餐", [style, schedule, knee, food, allergy])]
  for (question, expected) in mixedTasks {
    check(ids(question) == named(expected), "Only individual task targets contribute memory domains in mixed questions: " + question)
  }
  check(ids("晚饭吃什么") == named([style, food, allergy]), "Meal questions include preferences and allergy but omit training schedule and knee restriction")
  check(ids("今天怎么练") == named([style, schedule, knee]), "Training questions include schedule and movement restriction but omit food-only memories")
  check(ids("帮我安排今天练背") == named([style, schedule, knee]), "Concrete training wording retains relevant constraints")
  check(ids("晚饭吃什么", enabled: false).isEmpty, "Disabled memory scope excludes every memory including reply style")
  check(ids("你记得我哪些偏好") == named([style, food, schedule, allergy, knee, general]), "Explicit personal recall includes only valid active unforgotten authorized memory")
  check(ids("你记得我哪些偏好", enabled: false).isEmpty, "Explicit recall never overrides disabled memory consent")
  let systemic = memory("医生说目前需要注意用药限制", "health_constraint")
  var limited = data; limited.personalAgent?.memories.append(systemic)
  check(ids("午餐怎么搭配", limited).contains("memory." + systemic.id.uuidString) && ids("今天怎么练", limited).contains("memory." + systemic.id.uuidString), "Unclassified health restrictions remain available to relevant fitness tasks")
  check(!ids("你支持哪些模型", limited).contains("memory." + systemic.id.uuidString), "Health restrictions never rank themselves into unrelated software questions")

  func addTurn(_ question: String, answer: String, source: inout AppData, contextText: String? = nil, seconds: TimeInterval = -20) throws -> CoachTurn {
    let bundle = PersonalAgentContext.build(source, text: contextText ?? question, health: false, memory: true, now: now)
    let raw: [String: Any] = ["contract_version": 2, "request_id": UUID().uuidString, "snapshot_id": bundle.snapshot.snapshot_id,
      "expected_plan_version": bundle.snapshot.expected_plan_version, "status": "proposal", "message": answer, "questions": [String](), "cards": [[String: String]](), "operations": [[String: String]]()]
    let response = try JSONDecoder().decode(CoachAssistantResponse.self, from: JSONSerialization.data(withJSONObject: raw))
    var turn = CoachTurn(text: question, reply: answer, actions: [])
    turn.date = now.addingTimeInterval(seconds); turn.requiresMemoryConsent = true
    turn.exchange = CoachExchange(bundle: bundle, response: response)
    CoachThreads.record(turn, into: &source)
    return turn
  }
  func history(_ text: String, _ source: AppData, enabled: Bool = true) -> [RouterHistory] {
    PersonalAgentContext.history(source, text: text, health: false, memory: enabled, now: now)
  }
  let mealAnswer = "你对花生过敏，这餐先选不含花生的清淡饭菜。"
  var conversation = data
  _ = try addTurn("晚饭吃什么", answer: mealAnswer, source: &conversation)
  check(ids("刚才为什么这样安排", conversation) == named([style, food, allergy]), "A short why follow-up inherits the preceding meal task's relevant memories")
  check(history("刚才为什么这样安排", conversation).contains { $0.content == mealAnswer }, "Same-task follow-up keeps the usable prior answer and conversation continuity")
  _ = try addTurn("刚才为什么这样安排", answer: "这是沿用你已经核对的忌口。", source: &conversation, seconds: -10)
  check(ids("继续", conversation) == named([style, food, allergy]), "A chain of short follow-ups stays in the bounded preceding task")
  let switched = history("你支持哪些模型", conversation)
  check(!switched.contains { $0.content.contains("花生") || $0.content.contains("已经核对的忌口") }, "Switching topics omits prior assistant replies derived from now-irrelevant memory")
  check(switched.contains { $0.role == "user" && $0.content == "晚饭吃什么" }, "History filtering keeps safe user questions instead of clearing the whole thread")
  check(!history("晚饭吃什么", conversation, enabled: false).contains { $0.content.contains("花生") }, "Turning memory off also blocks memory echoes in recent assistant history")
  _ = try addTurn("你支持哪些模型", answer: "可在设置中查看。", source: &conversation, seconds: -5)
  check(ids("为什么", conversation) == named([style]), "Follow-up after a software topic does not jump back into an older fitness task")

  var mixed = data
  _ = try addTurn("晚饭吃什么", answer: "你周二训练，膝盖旧伤，所以晚饭清淡。", source: &mixed, contextText: "你记得我哪些偏好")
  check(!history("晚饭怎么换一种", mixed).contains { $0.content.contains("膝盖") }, "Old overbroad memory snapshots cannot leak through a same-task reply")
  check(history("晚饭怎么换一种", mixed).contains { $0.content == "晚饭吃什么" }, "A safely retained original question supports recovery from an overbroad old reply")
  var changed = data
  _ = try addTurn("晚饭吃什么", answer: mealAnswer, source: &changed)
  changed.personalAgent?.memories[3].revision += 1
  check(!history("继续", changed).contains { $0.content == mealAnswer }, "History cannot reuse an answer grounded in an older memory revision")
  changed = data
  _ = try addTurn("晚饭吃什么", answer: mealAnswer, source: &changed)
  changed.personalAgent?.memories[3].expiresAt = now.addingTimeInterval(-1)
  check(!history("继续", changed).contains { $0.content == mealAnswer }, "Expired memory cannot return through a recent answer")
  changed.personalAgent?.historyAfter = now
  check(history("继续", changed).isEmpty, "Correction/forget history cutoff remains enforced")

  var sourceTurns = data
  var sourceTurn = CoachTurn(text: food.content, reply: "已收到你的偏好。", actions: [])
  sourceTurn.date = now.addingTimeInterval(-10)
  sourceTurns.personalAgent?.memories[1].sourceTurnID = sourceTurn.id
  CoachThreads.record(sourceTurn, into: &sourceTurns)
  check(history("你支持哪些模型", sourceTurns).isEmpty, "Old unflagged source turns cannot resend an unrelated memory")
  check(history("晚饭吃什么", sourceTurns, enabled: false).isEmpty, "Memory source text is excluded when consent is disabled")

  #if DEBUG
  // Exercise the production request encoder used by both respondV2 and streaming,
  // with its real consent, snapshot and history fields (no network request).
  let transport = MealAgentTransport(endpoint: URL(string: "https://example.invalid")!, token: String(repeating: "x", count: 32))
  for (text, expected) in mixedTasks {
    let bundle = PersonalAgentContext.build(mixed, text: text, health: false, memory: true, now: now)
    let body = try transport.assistantBody(id: "mixed-domain-regression", text: text, history: history(text, mixed), snapshot: bundle.snapshot,
      health: false, memory: true, learning: false, model: nil)
    let payload = try JSONSerialization.jsonObject(with: body) as! [String: Any]
    let facts = (payload["snapshot"] as! [String: Any])["facts"] as! [[String: Any]]
    let actual = Set(facts.compactMap { $0["id"] as? String }.filter { $0.hasPrefix("memory.") })
    check(actual == named(expected), "Mixed-task production JSON contains only the requested personal domains: " + text)
    let json = String(decoding: body, as: UTF8.self)
    let forbidden = [(schedule, "周二"), (knee, "膝盖"), (allergy, "花生"), (food, "清淡"), (general, "蓝色")].filter { !expected.map(\.id).contains($0.0.id) }
    check(forbidden.allSatisfy { !json.contains($0.1) }, "Mixed-task production JSON does not reintroduce unrelated memory through history: " + text)
  }
  for text in productUsageQuestions {
    let bundle = PersonalAgentContext.build(data, text: text, health: false, memory: true, now: now)
    let body = try transport.assistantBody(id: "product-usage-regression", text: text, history: [], snapshot: bundle.snapshot,
      health: false, memory: true, learning: false, model: nil)
    let json = String(decoding: body, as: UTF8.self)
    check(!json.contains("花生") && !json.contains("膝盖") && !json.contains("周二晚上") && !json.contains("蓝色界面"), "Fresh-thread product usage JSON omits personal facts: " + text)
    let continued = PersonalAgentContext.build(mixed, text: text, health: false, memory: true, now: now)
    let historicalBody = try transport.assistantBody(id: "product-history-regression", text: text, history: history(text, mixed), snapshot: continued.snapshot,
      health: false, memory: true, learning: false, model: nil)
    check(!String(decoding: historicalBody, as: UTF8.self).contains("膝盖"), "Product usage question also excludes personal-memory echoes from prior history: " + text)
  }
  for (text, enabled, expected) in [("你支持哪些模型", true, named([style])), ("晚饭吃什么", true, named([style, food, allergy])), ("今天怎么练", true, named([style, schedule, knee])), ("晚饭吃什么", false, Set<String>())] {
    let bundle = PersonalAgentContext.build(conversation, text: text, health: false, memory: enabled, now: now)
    let body = try transport.assistantBody(id: "memory-regression", text: text, history: history(text, conversation, enabled: enabled), snapshot: bundle.snapshot,
      health: false, memory: enabled, learning: false, model: nil)
    let payload = try JSONSerialization.jsonObject(with: body) as! [String: Any]
    let snapshot = payload["snapshot"] as! [String: Any]
    let facts = snapshot["facts"] as! [[String: Any]]
    let actual = Set(facts.compactMap { $0["id"] as? String }.filter { $0.hasPrefix("memory.") })
    check(actual == expected && (payload["consent_scope"] as? [String: Bool])?["memory_summary"] == enabled, "Actual serialized request obeys task relevance and consent: " + text + " / " + String(enabled))
    if text == "你支持哪些模型" || !enabled {
      let json = String(decoding: body, as: UTF8.self)
      check(!json.contains("花生") && !json.contains("膝盖") && !json.contains("周二晚上"), "Actual request body omits unrelated or disabled memories in facts and history")
    }
  }
  #endif
}
