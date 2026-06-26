import SwiftUI

/// Chat-first face of a session: a full-height transcript with the composer
/// pinned at the bottom. SQL and results render inline at their
/// chronological position in the thread — permanent entries that scroll up
/// as the conversation grows. Only the newest SQL card is runnable; a fresh
/// session is just a hint and the composer.
struct ChatModeView: View {
    @Environment(AppState.self) private var appState
    let controller: SessionController

    private static let activeCardID = "activeSQLCard"
    private static let generatingID = "generating"
    private static let runningID = "runningQuery"

    var body: some View {
        @Bindable var chatVM = controller.chatVM

        VStack(spacing: 0) {
            if let message = appState.modelAvailabilityMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            if !isEmpty, let schemaStatus {
                SchemaStatusBanner(status: schemaStatus) {
                    Task { await appState.refreshSchema(for: controller.connectionID) }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }

            if isEmpty {
                emptyHint
            } else {
                transcript
            }

            ComposerView(
                text: $chatVM.input,
                isBusy: controller.chatVM.isGenerating
                    || controller.queryVM.isRunning
                    || isSchemaPreparing
            ) {
                Task { await controller.submit(appState: appState) }
            }
        }
    }

    private var hasActiveSQL: Bool {
        !controller.queryVM.sqlText
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isEmpty: Bool {
        controller.chatVM.messages.isEmpty
            && !hasActiveSQL
            && !controller.chatVM.isGenerating
    }

    private var sessionTitle: String {
        appState.session(for: controller.sessionID)?.displayTitle ?? QuerySession.placeholderTitle
    }

    private var connectionStatus: AppState.ConnectionStatus {
        appState.connectionState(controller.connectionID)
    }

    private var isSchemaPreparing: Bool {
        connectionStatus == .connecting || appState.loadingSchemas.contains(controller.connectionID)
    }

    private var hasLoadedSchema: Bool {
        appState.schemas[controller.connectionID] != nil
    }

    private var schemaStatus: SchemaStatus? {
        if isSchemaPreparing {
            return .loading
        }
        if case .error(let message) = connectionStatus {
            return .connectionError(message)
        }
        if connectionStatus == .connected && !hasLoadedSchema {
            return .missing
        }
        return nil
    }

    /// The message that introduced the SQL currently in the preview — the
    /// last generation, or the last directly-typed SQL. The active card
    /// renders right after it, keeping the thread chronological.
    private var activeSQLAnchorID: UUID? {
        controller.chatVM.messages.last(where: { message in
            switch message.role {
            case .assistant:
                return !(message.generation?.sql ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .user:
                return ChatViewModel.isDirectSQL(message.text)
            case .activity, .error, .result:
                return false
            }
        })?.id
    }

    /// True until something answers the active SQL (a result or an error
    /// after its anchor) — while waiting, the card carries the highlight.
    private var activeSQLAwaitingRun: Bool {
        let messages = controller.chatVM.messages
        guard let anchorID = activeSQLAnchorID,
            let anchorIndex = messages.firstIndex(where: { $0.id == anchorID })
        else { return true }
        return !messages[(anchorIndex + 1)...].contains {
            $0.role == .result || $0.role == .error
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            if let schemaStatus {
                SchemaEmptyStatusView(status: schemaStatus) {
                    Task { await appState.refreshSchema(for: controller.connectionID) }
                }
            } else {
                Text("Ask your database anything")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Type a question in plain English, or paste SQL to run it as-is.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            // Content fills from the top on purpose. `.defaultScrollAnchor(.bottom)`
            // translates short content to the bottom visually but leaves the hit-test
            // regions top-aligned on macOS 26, making every button in the
            // transcript unclickable.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(controller.chatVM.messages) { message in
                        messageGroup(message)
                            .id(message.id)
                    }
                    if controller.chatVM.isGenerating {
                        LoadingView(
                            label: controller.chatVM.generationStatus
                                ?? "Generating SQL with \(appState.activeBackendDisplayName)…"
                        )
                        .id(Self.generatingID)
                    }
                    if controller.queryVM.isRunning {
                        HStack(spacing: 8) {
                            LoadingView(label: "Running query…")
                            if controller.queryVM.canStopWaiting {
                                Button("Stop waiting") {
                                    controller.queryVM.cancelRun()
                                }
                                .controlSize(.small)
                                .hoverBrightness()
                            }
                        }
                        .id(Self.runningID)
                    }
                    // Restored sessions can carry SQL whose introducing
                    // message is gone; keep it runnable at the end.
                    if hasActiveSQL && activeSQLAnchorID == nil {
                        SQLCardView(controller: controller)
                            .id(Self.activeCardID)
                    }
                }
                .padding(12)
            }
            .onAppear {
                // LazyVStack needs a layout pass before scrollTo can resolve ids.
                Task { @MainActor in scrollToBottom(proxy, animated: false) }
            }
            .onChange(of: controller.chatVM.messages.count) { scrollToBottom(proxy) }
            .onChange(of: controller.chatVM.isGenerating) { scrollToBottom(proxy) }
            .onChange(of: controller.queryVM.isRunning) { scrollToBottom(proxy) }
            .onChange(of: controller.queryVM.sqlText) { scrollToBottom(proxy) }
            .contextMenu {
                Button("Clear Conversation") {
                    controller.clearConversation()
                    appState.sessionDidChange(controller.sessionID)
                }
            }
        }
    }

    /// One chronological transcript entry: run records render their full
    /// results card while the result is in memory; the SQL-introducing
    /// messages carry their card right below the bubble — the newest one
    /// runnable, earlier ones as permanent static records.
    @ViewBuilder
    private func messageGroup(_ message: ChatMessage) -> some View {
        if message.role == .result, let result = controller.results[message.id] {
            ResultsCardView(
                result: result,
                sessionTitle: sessionTitle,
                isLatest: message.id == controller.chatVM.messages.last?.id
            )
        } else if message.id == activeSQLAnchorID, hasActiveSQL {
            VStack(alignment: .leading, spacing: 10) {
                MessageBubbleView(
                    message: message,
                    onClarificationOptionSelected: selectClarificationOption
                )
                SQLCardView(controller: controller, isAwaitingRun: activeSQLAwaitingRun)
            }
        } else if message.role == .assistant,
            let sql = message.generation?.sql,
            !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            VStack(alignment: .leading, spacing: 10) {
                MessageBubbleView(
                    message: message,
                    onClarificationOptionSelected: selectClarificationOption
                )
                StaticSQLCardView(sql: sql)
            }
        } else {
            MessageBubbleView(
                message: message,
                onRetryWrite: retryWriteAction(for: message),
                onClarificationOptionSelected: selectClarificationOption
            )
        }
    }

    /// Only a failed-write error that is the newest message owns the "Try Again"
    /// button. Once a retry appends a new generation (or the session is reopened
    /// onto later history), the affordance retires — it always points at the
    /// query the user is currently looking at, and the lookup stays O(1).
    private var lastWriteErrorID: UUID? {
        guard let last = controller.chatVM.messages.last,
            last.role == .error, last.failedWriteSQL != nil
        else { return nil }
        return last.id
    }

    private func retryWriteAction(for message: ChatMessage) -> (() -> Void)? {
        guard message.id == lastWriteErrorID, let failedSQL = message.failedWriteSQL else {
            return nil
        }
        return {
            Task {
                await controller.retryFailedWrite(
                    appState: appState, failedSQL: failedSQL, error: message.text)
            }
        }
    }

    private func selectClarificationOption(
        pending: PendingClarification,
        option: ClarificationOption
    ) {
        Task {
            await controller.selectClarificationOption(
                appState: appState,
                pending: pending,
                option: option
            )
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        withAnimation(animated ? .default : nil) {
            if controller.queryVM.isRunning {
                proxy.scrollTo(Self.runningID, anchor: .bottom)
            } else if controller.chatVM.isGenerating {
                proxy.scrollTo(Self.generatingID, anchor: .bottom)
            } else if hasActiveSQL && activeSQLAnchorID == nil {
                proxy.scrollTo(Self.activeCardID, anchor: .bottom)
            } else if let lastID = controller.chatVM.messages.last?.id {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }
}

private enum SchemaStatus: Equatable {
    case loading
    case missing
    case connectionError(String)

    var title: String {
        switch self {
        case .loading:
            return "Loading Database Schema"
        case .missing:
            return "Schema Not Loaded"
        case .connectionError:
            return "Database Connection Failed"
        }
    }

    var message: String {
        switch self {
        case .loading:
            return "Tables and columns are loading. Natural-language questions will be available once the schema is ready."
        case .missing:
            return "Natural-language questions need table and column context. Direct SQL can still be pasted and run."
        case .connectionError(let message):
            return message
        }
    }

    var systemImage: String {
        switch self {
        case .loading:
            return "tablecells.badge.ellipsis"
        case .missing:
            return "exclamationmark.triangle"
        case .connectionError:
            return "xmark.octagon"
        }
    }

    var tint: Color {
        switch self {
        case .loading:
            return .accentColor
        case .missing:
            return .orange
        case .connectionError:
            return .red
        }
    }

    var canRefresh: Bool {
        self == .missing
    }
}

private struct SchemaStatusBanner: View {
    let status: SchemaStatus
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if status == .loading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: status.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(status.tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.caption.weight(.semibold))
                Text(status.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if status.canRefresh {
                Button("Refresh Schema", action: refresh)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(status.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(status.tint.opacity(0.22))
        }
    }
}

private struct SchemaEmptyStatusView: View {
    let status: SchemaStatus
    let refresh: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if status == .loading {
                LoadingView(label: status.title)
            } else {
                Image(systemName: status.systemImage)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(status.tint)
                Text(status.title)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Text(status.message)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            if status.canRefresh {
                Button("Refresh Schema", action: refresh)
                    .widenGlassButtonStyle()
                    .hoverBrightness()
            }
        }
    }
}
