import SwiftUI

struct ContentTabView: View {
    @EnvironmentObject var appVM: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            if appVM.tableVM.isLoadingContent {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result = appVM.tableVM.contentResult, !result.columns.isEmpty {
                ResultsGridView(result: result)
            } else {
                VStack {
                    Text("Select a table and switch to Content to browse rows.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    if appVM.navigatorVM.selectedObject != nil, appVM.tableVM.contentResult == nil {
                        Task { await appVM.loadContentPage() }
                    }
                }
            }

            Divider()
            paginationBar
        }
    }

    private var paginationBar: some View {
        HStack {
            Picker("Rows:", selection: $appVM.tableVM.pageSize) {
                ForEach(appVM.tableVM.pageSizeOptions, id: \.self) { size in
                    Text("\(size)").tag(size)
                }
            }
            .frame(width: 130)
            .onChange(of: appVM.tableVM.pageSize) { _ in
                appVM.tableVM.currentPage = 0
                Task { await appVM.loadContentPage() }
            }

            Spacer()

            Button {
                appVM.tableVM.currentPage = max(0, appVM.tableVM.currentPage - 1)
                Task { await appVM.loadContentPage() }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(appVM.tableVM.currentPage <= 0)

            Text("Page \(appVM.tableVM.currentPage + 1) of \(appVM.tableVM.totalPages)")
                .monospacedDigit()

            Button {
                appVM.tableVM.currentPage = min(appVM.tableVM.totalPages - 1, appVM.tableVM.currentPage + 1)
                Task { await appVM.loadContentPage() }
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(appVM.tableVM.currentPage >= appVM.tableVM.totalPages - 1)

            Spacer()

            Text("\u{2248} \(appVM.tableVM.approximateRowCount) rows")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
