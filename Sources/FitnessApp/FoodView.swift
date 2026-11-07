import FitnessCore
import PhotosUI
import SwiftUI

struct FoodView: View {
  @EnvironmentObject var store: AppStore
  @State private var minutes = 30
  @State private var showLog = false
  @State private var repeatedMeal: MealEntry?
  @State private var manageRecords = false
  @State private var recipe: Recipe?
  private var suggestions: [MealSuggestion] {
    MealEngine.suggest(
      pantry: store.data.pantry, excluded: store.data.profile.excludedFoods, maxMinutes: minutes,
      reviewed: store.data.profile.allergiesReviewed)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Surface(dark: true) {
        Pill(text: "饮食日记 · 你上传，我汇总", dark: true)
        Text("吃了什么，\n记下来就看得见。").font(.system(size: 30, weight: .bold))
        Text("上传食物照片、份量和已知营养数据，\n汇总今天已记录的摄入与缺失信息。").font(.system(size: 14)).foregroundStyle(
          .white.opacity(0.8))
      }
      FoodDiaryCard(onLog: { showLog = true }, onEdit: { manageRecords = true })
      DisclosureGroup("需要时，再帮我搭配下一餐") {
      VStack(alignment: .leading, spacing: 18) {
      Surface {
        Text("先核对饮食限制").font(.system(size: 18, weight: .bold))
        Toggle(
          "我已核对下方不吃 / 过敏的食物",
          isOn: Binding(
            get: { store.data.profile.allergiesReviewed },
            set: { v in _ = store.change { $0.profile.allergiesReviewed = v } })
        ).tint(Color.pine).font(.system(size: 13))
        Text("没有需要排除的食物也请明确确认。复合食品还要看包装标签。").font(.system(size: 12)).foregroundStyle(
          Color.secondaryInk)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84))], spacing: 8) {
          ForEach(FoodCatalog.ingredients) { item in
            Button {
              _ = store.change {
                if $0.profile.excludedFoods.contains(item.id) {
                  $0.profile.excludedFoods.remove(item.id)
                } else {
                  $0.profile.excludedFoods.insert(item.id)
                }
              }
            } label: {
              Text((store.data.profile.excludedFoods.contains(item.id) ? "避开 " : "") + item.name)
                .font(.system(size: 12)).padding(.vertical, 10).frame(maxWidth: .infinity)
                .background(
                  store.data.profile.excludedFoods.contains(item.id)
                    ? Color.orange.opacity(0.15) : Color.canvas,
                  in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain)
          }
        }
      }
      Surface {
        HStack {
          Text("家里有什么？").font(.system(size: 19, weight: .bold))
          Spacer()
          Text(DailyPlanner.pantryFresh(store.data) ? "今日库存已确认" : "待你确认").font(.system(size: 11))
            .foregroundStyle(Color.secondaryInk)
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 89))], spacing: 9) {
          ForEach(FoodCatalog.ingredients) { item in
            Button {
              store.toggleFood(item.id)
            } label: {
              HStack(spacing: 5) {
                Image(
                  systemName: store.data.pantry.contains(item.id)
                    ? "checkmark.circle.fill" : "circle")
                Text(item.name)
              }.font(.system(size: 13, weight: .medium)).padding(.vertical, 12).frame(
                maxWidth: .infinity
              ).background(
                store.data.pantry.contains(item.id) ? Color.mist : Color.canvas,
                in: RoundedRectangle(cornerRadius: 11)
              ).foregroundStyle(Color.pine)
            }.buttonStyle(.plain).accessibilityLabel("库存 \(item.name)")
          }
        }
        if !DailyPlanner.pantryFresh(store.data) {
          Text("请核对今天实际还有的食材；初始勾选仅是示例。").font(.system(size: 12)).foregroundStyle(Color.secondaryInk)
          Button("确认这些食材目前有") { store.confirmPantry() }.buttonStyle(.borderedProminent).tint(
            Color.pine)
        }
        FieldLabel(title: "这餐有多少准备时间？")
        Picker("准备时间", selection: $minutes) {
          Text("15 分钟").tag(15)
          Text("30 分钟").tag(30)
          Text("45 分钟").tag(45)
        }.pickerStyle(.segmented)
      }
      Subheading(title: "这餐可以这样搭", detail: "候选方案")
      if !store.data.profile.allergiesReviewed {
        Surface {
          EmptyHint(symbol: "checkmark.shield", title: "先确认饮食限制", detail: "确认上方过敏和忌口后，再给出搭配候选。")
        }
      } else if !DailyPlanner.pantryFresh(store.data) {
        Surface { Text("先确认上方现有食材，再查看下一餐的搭配。") }
      } else if suggestions.isEmpty {
        Surface {
          EmptyHint(
            symbol: "leaf", title: "暂时没有合适搭配", detail: "现有菜谱无法同时满足限制和时间。可以调整准备时间；不要取消真实过敏限制。")
        }
      } else {
        ForEach(Array(suggestions.prefix(3))) { suggestion in
          Button {
            recipe = suggestion.recipe
          } label: {
            Surface {
              HStack {
                Pill(text: suggestion.ready ? "食材齐全" : "还需要 \(suggestion.missing.count) 样")
                Spacer()
                Label("\(suggestion.recipe.minutes) 分钟", systemImage: "clock").font(
                  .system(size: 12)
                ).foregroundStyle(Color.secondaryInk)
              }
              Text(suggestion.recipe.name).font(.system(size: 21, weight: .bold))
              Text(
                suggestion.recipe.ingredients.map { FoodCatalog.name($0) }.joined(separator: " · ")
              ).font(.system(size: 13)).foregroundStyle(Color.secondaryInk)
              if !suggestion.missing.isEmpty {
                Text(
                  "待准备：" + suggestion.missing.map { FoodCatalog.name($0) }.joined(separator: "、")
                ).font(.system(size: 12)).foregroundStyle(Color.secondaryInk)
              }
              HStack {
                Text("查看做法与记录").font(.system(size: 13, weight: .medium))
                Spacer()
                Image(systemName: "arrow.right")
              }.foregroundStyle(Color.pine)
            }
          }.buttonStyle(.plain)
        }
      }
      }
      }
      MainButton(title: "上传吃过的食物 / 再记一餐", symbol: "plus") { showLog = true }
      if !store.data.meals.isEmpty {
        Surface {
          Text("和上次吃得差不多？").font(.headline)
          ForEach(Array(store.data.meals.sorted { $0.date > $1.date }.prefix(3))) { item in
            Button("再记一餐 · " + item.title) { repeatedMeal = item }
          }
          Text("带入文字后由你确认，照片不会当作今天的餐食复用。").font(.caption).foregroundStyle(Color.secondaryInk)
        }
      }
      Surface {
        Text("今天还缺什么？").font(.system(size: 18, weight: .bold))
        Text("已确认 \(store.todayMeals.count) 条饮食记录。当前还没有完整的餐食份量和经过核验的每日目标，所以不会编造能量或蛋白质缺口。").font(
          .system(size: 13)
        ).foregroundStyle(Color.secondaryInk)
      }
      if !store.todayMeals.isEmpty {
        Subheading(title: "今天吃过的", detail: "已确认记录")
        ForEach(store.todayMeals.reversed()) { meal in MealRow(meal: meal) }
      }
    }
    .onAppear { minutes = store.data.coach?.preferences.cookingMinutes ?? 30 }
    .sheet(isPresented: $manageRecords) { RecordManager() }
    .sheet(isPresented: $showLog) { MealLogSheet() }
    .sheet(item: $repeatedMeal) { MealLogSheet(prefill: $0) }
    .sheet(item: $recipe) { item in RecipeSheet(recipe: item) }
  }
}
struct MealRow: View {
  @EnvironmentObject var store: AppStore
  let meal: MealEntry
  var body: some View {
    Surface {
      HStack(alignment: .top) {
        if let name = meal.photoName, let bytes = store.photo(name) {
          LocalPhoto(bytes: bytes).frame(width: 65, height: 65).clipped().clipShape(
            RoundedRectangle(cornerRadius: 12))
        }
        VStack(alignment: .leading, spacing: 5) {
          Text(meal.title).font(.system(size: 16, weight: .semibold))
          if !meal.note.isEmpty {
            Text(meal.note).font(.system(size: 12)).foregroundStyle(Color.secondaryInk)
          }
          if let facts = meal.nutrition, let energy = facts.actualEnergyKcal {
            Text("已填 \(energy, specifier: "%.1f") kcal · \(facts.source)").font(.caption)
          }
          Text(meal.date, format: .dateTime.hour().minute()).font(.system(size: 11))
            .foregroundStyle(Color.secondaryInk)
        }
        Spacer()
        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.pine)
      }
    }
  }
}
struct RecipeSheet: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  let recipe: Recipe
  @State private var note = ""
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack {
          Pill(text: "搭配候选 · 本地规则")
          Spacer()
          Button("关闭") { dismiss() }
        }
        Text(recipe.name).font(.system(size: 29, weight: .bold))
        Text(recipe.ingredients.map { FoodCatalog.name($0) }.joined(separator: " · "))
          .foregroundStyle(Color.secondaryInk)
        ForEach(Array(recipe.directions.enumerated()), id: \.offset) { i, line in
          HStack(alignment: .top) {
            Text("\(i+1)").font(.headline).foregroundStyle(Color.pine)
            Text(line).font(.system(size: 15))
          }
        }
        Text(recipe.note).font(.system(size: 12)).foregroundStyle(Color.secondaryInk)
        Text("实际份量 / 有哪些调整？").font(.headline)
        TextField("例如：鸡蛋 2 个，米饭一小碗", text: $note, axis: .vertical).entryField()
        MainButton(title: "我已经吃了，保存这一餐", symbol: "checkmark") {
          guard store.data.profile.allergiesReviewed, Set(recipe.ingredients).isDisjoint(with: store.data.profile.excludedFoods) else {
            store.alert = "饮食限制已变化，请重新选择搭配。"; return
          }
          if store.addMeal(title: recipe.name, note: note, photo: nil) { dismiss() }
        }
        Text("只在你确认吃完后计入饮食记录；计划中的餐食不会算作已摄入。").font(.caption).foregroundStyle(Color.secondaryInk)
      }.padding(26)
    }.background(Color.canvas).frame(minWidth: 340, minHeight: 480)
  }
}
struct LocalPhoto: View, Equatable {
  let bytes: Data
  var body: some View {
    #if os(iOS)
      if let image = UIImage(data: bytes) { Image(uiImage: image).resizable().scaledToFill() }
    #else
      if let image = NSImage(data: bytes) { Image(nsImage: image).resizable().scaledToFill() }
    #endif
  }
}
struct MealLogSheet: View {
  var prefill: MealEntry? = nil
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  @State private var title = ""
  @State private var note = ""
  @State private var selectedPhoto: PhotosPickerItem?
  @State private var photo: Data?
  @State private var photoError: String?
  @State private var facts = MealNutrition()
  @State private var showFacts = false
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack {
          Text("记录一餐").font(.system(size: 27, weight: .bold))
          Spacer()
          Button("取消") { dismiss() }
        }
        Text("上传餐食照片或营养标签，补充名称与实际份量。照片默认保存在本机；连接饮食 Agent 并确认上传后，可先分析再核对。").font(.system(size: 13)).foregroundStyle(
          Color.secondaryInk)
        PhotosPicker(selection: $selectedPhoto, matching: .images) {
          HStack {
            Image(systemName: "photo.badge.plus")
            Text(photo == nil ? "添加餐食照片" : "更换照片")
          }.frame(maxWidth: .infinity).padding(22).background(
            Color.mist, in: RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(.plain)
        if let photo {
          LocalPhoto(bytes: photo).frame(height: 180).clipped().clipShape(
            RoundedRectangle(cornerRadius: 16))
        }
        if let photoError { Text(photoError).font(.caption).foregroundStyle(.red) }
        FieldLabel(title: "实际吃了什么")
        TextField("例如：番茄鸡蛋饭", text: $title).entryField()
        FieldLabel(title: "份量、饮料或其他补充")
        TextField("简单描述即可，不知道的可以留空", text: $note, axis: .vertical).entryField()
        MealAISection(title: $title, note: $note, photo: photo, facts: $facts, showFacts: $showFacts)
        DisclosureGroup("补充营养数据（可选）", isExpanded: $showFacts) { NutritionFields(facts: $facts).padding(.top, 12) }
        MainButton(title: "确认吃过并保存", symbol: "checkmark") {
          if store.addMeal(title: title, note: note, photo: photo, nutrition: facts.hasNumbers || facts.grams != nil ? facts : nil) { dismiss() }
        }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }.padding(26)
    }.background(Color.canvas).frame(minWidth: 340, minHeight: 500)
      .onAppear { if let prefill { title = prefill.title; note = prefill.note } }
      .onChange(of: selectedPhoto) { _, item in
        Task {
          do {
            if let bytes = try await item?.loadTransferable(type: Data.self) {
              guard bytes.count <= 20_000_000 else {
                photoError = "照片较大，请选择 20 MB 以内的图片。"
                return
              }
              guard selectedPhoto == item else { return }
              photo = bytes
              photoError = nil
            }
          } catch { photoError = "暂时无法读取这张照片。" }
        }
      }
  }
}
