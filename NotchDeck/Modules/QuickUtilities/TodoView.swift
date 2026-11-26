import SwiftUI

/// Expanded To-Dos: an add field and the checklist (click to tick, double-click to edit).
struct TodosModuleView: View {
    let tokens: ThemeTokens

    @Environment(TodoStore.self) private var todos
    @State private var draft = ""
    @FocusState private var isAddFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(tokens.secondaryText)
                TextField("Add a to-do and press Return", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($isAddFocused)
                    .onSubmit {
                        todos.add(draft)
                        draft = ""
                        isAddFocused = true
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(tokens.controlFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            if todos.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checklist").font(.system(size: 22)).foregroundStyle(tokens.secondaryText)
                    Text("Nothing to do. Add something above.")
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(todos.sortedItems) { item in
                            TodoRow(item: item, tokens: tokens)
                        }
                    }
                }
                .scrollIndicators(.never)

                HStack {
                    Text(todos.openCount == 0 ? "All done" : "\(todos.openCount) left")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(tokens.secondaryText)
                    if let error = todos.lastError {
                        Text(error).font(.system(size: 10.5)).foregroundStyle(.orange).lineLimit(1)
                    }
                    Spacer()
                    if todos.doneCount > 0 {
                        NotchPillButton(title: "Clear Done", symbol: "checkmark.circle", tokens: tokens) { todos.clearDone() }
                    }
                }
            }
        }
    }
}

private struct TodoRow: View {
    let item: TodoItem
    let tokens: ThemeTokens

    @Environment(TodoStore.self) private var todos
    @State private var isHovering = false
    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var isEditFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button { withAnimation(.smooth(duration: 0.2)) { todos.toggle(item.id) } } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(item.isDone ? NotchStatusColor.good : tokens.secondaryText)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isDone ? "Mark as not done" : "Mark as done")

            if isEditing {
                TextField("To-do", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isEditFocused)
                    .onSubmit(commitEdit)
                    .onChange(of: isEditFocused) { _, focused in if !focused { commitEdit() } }
            } else {
                Text(item.title)
                    .font(.system(size: 12))
                    .strikethrough(item.isDone, color: tokens.secondaryText)
                    .foregroundStyle(item.isDone ? tokens.secondaryText : tokens.primaryText)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginEdit() }
            }

            if isHovering && !isEditing {
                Button { todos.delete(item.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(tokens.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Delete")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isHovering ? tokens.controlFill : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(item.isDone ? "Mark as Not Done" : "Mark as Done") { todos.toggle(item.id) }
            Button("Edit") { beginEdit() }
            Divider()
            Button("Delete") { todos.delete(item.id) }
        }
    }

    private func beginEdit() {
        editText = item.title
        isEditing = true
        isEditFocused = true
    }

    private func commitEdit() {
        guard isEditing else { return }
        isEditing = false
        if editText != item.title { todos.rename(item.id, to: editText) }
    }
}
