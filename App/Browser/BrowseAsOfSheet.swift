import SwiftUI

/// View ▸ Browse As Of…: picks the date and time to show the current folder at.
struct BrowseAsOfSheet: View {
  @Environment(\.dismiss) private var dismiss
  let browser: BrowserController

  @State private var date: Date

  init(browser: BrowserController) {
    self.browser = browser
    var initial = Date.now
    if case .asOf(let date) = browser.historyMode { initial = date }
    _date = State(initialValue: initial)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Browse As Of")
        .font(.title2.weight(.semibold))
      Text("Shows the files in this folder as they were at the chosen time. The bucket needs versioning.")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      DatePicker(
        "Date and time", selection: $date, in: ...Date.now, displayedComponents: [.date, .hourAndMinute]
      )
      .datePickerStyle(.graphical)
      .labelsHidden()
      HStack {
        if case .asOf = browser.historyMode {
          Button("Back to Now") {
            browser.exitHistory()
            dismiss()
          }
        }
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Show") {
          browser.historyMode = .asOf(date)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 460)
  }
}
