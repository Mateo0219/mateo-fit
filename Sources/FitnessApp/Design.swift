import SwiftUI

extension Color {
  static let hairline = Color.black.opacity(0.09)
  static let subtle = Color(red: 0.975, green: 0.975, blue: 0.98)
  static let success = Color(red: 0.18, green: 0.45, blue: 0.33)
  static let canvas = Color.white
  static let pine = Color(red: 0.09, green: 0.09, blue: 0.10)
  static let lime = Color.white
  static let ink = Color(red: 0.09, green: 0.09, blue: 0.10)
  static let secondaryInk = Color(red: 0.46, green: 0.46, blue: 0.48)
  static let mist = Color(red: 0.955, green: 0.955, blue: 0.96)
}
struct Surface<Content: View>: View {
  var dark = false
  @ViewBuilder var content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 14) { content }.frame(
      maxWidth: .infinity, alignment: .leading
    ).padding(18).background(
      dark ? Color.pine : Color.white, in: RoundedRectangle(cornerRadius: 18)
    ).overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(dark ? Color.clear : Color.hairline, lineWidth: 0.75)).foregroundStyle(dark ? Color.white : Color.ink)
  }
}
struct Pill: View {
  var text: String
  var dark = false
  var body: some View {
    Text(text).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 10).padding(
      .vertical, 6
    ).background(dark ? Color.white.opacity(0.12) : Color.mist, in: Capsule()).foregroundStyle(
      dark ? Color.lime : Color.pine)
  }
}
struct MainButton: View {
  @Environment(\.isEnabled) private var isEnabled
  var title: String
  var symbol: String = "arrow.right"
  var action: () -> Void
  var body: some View {
    Button(action: action) {
      HStack {
        Text(title)
        Spacer()
        Image(systemName: symbol)
      }.font(.system(size: 15, weight: .semibold)).padding(16).background(
        Color.pine.opacity(isEnabled ? 1 : 0.3), in: RoundedRectangle(cornerRadius: 14)
      ).foregroundStyle(.white)
    }.buttonStyle(.plain)
  }
}
struct Subheading: View {
  var title: String
  var detail: String = ""
  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title).font(.system(size: 21, weight: .bold))
      Spacer()
      Text(detail).font(.system(size: 11)).foregroundStyle(Color.secondaryInk)
    }.foregroundStyle(Color.ink).padding(.top, 6)
  }
}
struct EmptyHint: View {
  var symbol: String
  var title: String
  var detail: String
  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: symbol).font(.system(size: 25)).foregroundStyle(Color.pine)
      Text(title).font(.system(size: 16, weight: .semibold))
      Text(detail).font(.system(size: 13)).foregroundStyle(Color.secondaryInk)
        .multilineTextAlignment(.center)
    }.frame(maxWidth: .infinity).padding(.vertical, 20)
  }
}
struct FieldLabel: View {
  var title: String
  var body: some View {
    Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.secondaryInk)
  }
}
extension View {
  func entryField() -> some View {
    self.textFieldStyle(.plain).padding(13).background(
      Color.mist, in: RoundedRectangle(cornerRadius: 12))
  }
}

struct BrandLogo: View {
  var body: some View {
    #if os(iOS)
    Image("BrandMark").resizable().scaledToFit().accessibilityHidden(true)
    #else
    if let image = NSImage(named: "BrandMark") {
      Image(nsImage: image).resizable().scaledToFit().accessibilityHidden(true)
    } else {
      Image(systemName: "dumbbell.fill").foregroundStyle(Color.pine).accessibilityHidden(true)
    }
    #endif
  }
}
