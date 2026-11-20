import SwiftUI

/// The bell's sheet: the computer's notifications, newest first. Tapping one that belongs to a
/// conversation marks it read on the computer and opens it.
struct SquaddNotificationsSheet: View {
    let model: SquaddNotificationsModel
    let open: (SquaddNotification) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(model.items) { notification in
                Button { open(notification) } label: { SquaddNotificationRow(notification: notification) }
                    .disabled(notification.threadId == nil)
            }
            .listStyle(.plain)
            .overlay {
                if model.items.isEmpty {
                    if model.loadFailed {
                        ContentUnavailableView("Notifications unavailable.", systemImage: "bell.slash")
                    } else {
                        ContentUnavailableView("No Notifications", systemImage: "bell")
                    }
                }
            }
            .refreshable { await model.load() }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

private struct SquaddNotificationRow: View {
    let notification: SquaddNotification

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(notification.read ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(notification.title ?? notification.botName ?? "")
                        .font(AppFont.subheadline().weight(notification.read ? .regular : .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let at = notification.at {
                        Text(Date(timeIntervalSince1970: at / 1000).formatted(.relative(presentation: .named)))
                            .font(AppFont.caption())
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if let body = notification.body, !body.isEmpty {
                    Text(body)
                        .font(AppFont.footnote())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(notification.read ? Text(verbatim: "") : Text("Unread"))
    }
}
