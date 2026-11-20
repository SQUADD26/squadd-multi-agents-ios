import SwiftUI

/// A channel under Channels (#21), one line as the desktop lists it: tapping it opens its current
/// conversation, the arrow shows the others, and its menu starts one, renames the channel or deletes it.
struct SquaddRoomRow: View {
    let room: SquaddRoomSection
    let isExpanded: Bool
    /// Opens the channel's current conversation; nil shows its conversations instead.
    let open: (() -> Void)?
    let toggle: () -> Void
    let newThread: () -> Void
    let rename: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: open ?? toggle) { identity }.buttonStyle(.plain)
            SquaddThreadsToggle(isExpanded: isExpanded, toggle: toggle)
        }
        .padding(.leading, 24)
        .padding(.trailing, 6)
        .contextMenu {
            Button(action: newThread) { Label("New Thread", systemImage: "square.and.pencil") }
            Button(action: rename) { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive, action: delete) { Label("Delete Group Chat", systemImage: "trash") }
        }
        .accessibilityElement(children: .contain)
    }

    private var identity: some View {
        HStack(spacing: 10) {
            Image(systemName: "number")
                .foregroundStyle(.appSecondary)
                .frame(width: 32)
                .accessibilityHidden(true)
            SquaddRowName(name: room.name, isUnread: !room.unreadThreadIDs.isEmpty)
            Spacer(minLength: 4)
            SquaddRowStatus(isBusy: room.isBusy, isUnread: !room.unreadThreadIDs.isEmpty)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The first row inside an open agent or channel: a new thread, opened at once, and an agent's editor.
struct SquaddNewThreadRow: View {
    var edit: (() -> Void)?
    let action: () -> Void

    var body: some View {
        HStack {
            Button(action: action) {
                Label("New Thread", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            if let edit {
                Button(action: edit) {
                    Label("Edit Agent", systemImage: "slider.horizontal.3")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
        }
        .font(AppFont.subheadline())
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .padding(.leading, 40)
        .padding(.trailing, 6)
        .sessionsScreenListRow()
    }
}

extension SquaddThreadChat {
    /// A room's conversation: sends go to the room, `@` reaches its members.
    init(room: SquaddRoomSection, thread: SessionSummary, server: URL, token: String) {
        self.init(server: server, token: token, botId: room.id, threadId: thread.id, title: thread.title,
                  room: SquaddRoomChat(id: room.id, members: room.members))
    }
}
