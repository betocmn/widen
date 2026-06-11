import AppKit
import SwiftUI

/// Simple scrollable grid of stringified result values.
public struct QueryResultsView: View {
    private let controller: SessionController

    public init(controller: SessionController) {
        self.controller = controller
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
        }
        .padding(10)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Results")
                .font(.headline)
            Spacer()
            if let result = controller.queryVM.result {
                Text(summary(for: result))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Copy CSV") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.csv(), forType: .string)
                }
                .buttonStyle(.glass)
            }
        }
    }

    private func summary(for result: QueryResult) -> String {
        var parts = [
            "\(result.rowCount) row\(result.rowCount == 1 ? "" : "s")",
            "\(result.executionTimeMs) ms",
        ]
        if result.truncated {
            parts.append("truncated at row limit")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        let queryVM = controller.queryVM
        if queryVM.isRunning {
            VStack(spacing: 8) {
                LoadingView(label: "Running query…")
                Button("Stop waiting") {
                    queryVM.cancelRun()
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = queryVM.runError {
            VStack {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 8)
        } else if let result = queryVM.result {
            if result.columns.isEmpty {
                Text("The query returned no rows.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ResultsGridView(result: result)
            }
        } else {
            Text("Run a query to see results here.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
