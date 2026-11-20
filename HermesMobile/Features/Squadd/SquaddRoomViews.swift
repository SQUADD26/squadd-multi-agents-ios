import SwiftUI

/// A room's name over its conversations in the Squadd home (#21), set like an agent's header.
/// Its menu starts a conversation, renames the room or deletes it.
struct SquaddRoomHeader: View {
    let room: SquaddRoomSection
    let newThread: () -> Void
    let rename: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.3")
                .foregroundStyle(.appSecondary)
                .accessibilityHidden(true)
            Text(verbatim: room.name)
                .font(AppFont.title3().bold())
                .foregroundStyle(.appPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if room.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
            }
            Spacer()
            Menu {
                Button(action: newThread) { Label("New Thread", systemImage: "square.and.pencil") }
                Button(action: rename) { Label("Rename", systemImage: "pencil") }
                Button(role: .destructive, action: delete) { Label("Delete Group Chat", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.tint)
            .accessibilityLabel(Text("Actions for \(room.name)"))
        }
        .padding(.leading, 24)
        .padding(.trailing, 14)
        .padding(.top, 20)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
    }
}

extension SquaddThreadChat {
    /// A room's conversation: sends go to the room, `@` reaches its members.
    init(room: SquaddRoomSection, thread: SessionSummary, server: URL, token: String) {
        self.init(server: server, token: token, botId: room.id, threadId: thread.id, title: thread.title,
                  room: SquaddRoomChat(id: room.id, members: room.members))
    }
}
