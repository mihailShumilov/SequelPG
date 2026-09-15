import SwiftUI

/// Read-only view of `pg_roles` with a simple GRANT/REVOKE builder.
/// Managing passwords and complex RESOURCE LIMITS is out of scope — the user
/// can fall back to the SQL editor for those.
struct RolesSheet: View {
    @Environment(AppViewModel.self) var appVM
    @Environment(\.dismiss) private var dismiss

    @State private var roles: [RoleInfo] = []
    @State private var isLoading: Bool = true
    @State private var searchText: String = ""

    // GRANT builder state
    @State private var grantRole: String = ""
    @State private var grantPrivilege: String = "SELECT"
    @State private var grantTarget: String = ""
    @State private var grantResult: String?

    private let privileges = [
        "SELECT", "INSERT", "UPDATE", "DELETE", "TRUNCATE",
        "REFERENCES", "TRIGGER", "USAGE", "CREATE", "CONNECT", "TEMP", "EXECUTE", "ALL PRIVILEGES",
    ]

    private var filtered: [RoleInfo] {
        guard !searchText.isEmpty else { return roles }
        return roles.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var canGrant: Bool {
        !grantTarget.trimmingCharacters(in: .whitespaces).isEmpty
            && !grantRole.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Roles & Privileges")
                    .font(.headline)
                Spacer()
                SearchField(text: $searchText, prompt: "Search roles", controlSize: .regular)
                    .frame(width: 220)
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh list")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                rolesList
            }

            Divider()
            grantForm
            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 680, height: 600)
        .task { await reload() }
    }

    private var rolesList: some View {
        List {
            ForEach(filtered) { role in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: role.canLogin ? "person.fill" : "person.crop.circle")
                        .foregroundStyle(role.canLogin ? Color.accentColor : Color.secondary)
                        .frame(width: 20)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(role.name)
                                .font(.system(.body, design: .monospaced).weight(.medium))
                            if role.isSuperuser { Tag("superuser", color: Theme.rose) }
                            if !role.canLogin { Tag("nologin", color: .secondary) }
                            if role.canCreateDB { Tag("createdb", color: Theme.blue) }
                            if role.canCreateRole { Tag("createrole", color: Theme.blue) }
                            if role.isReplication { Tag("replication", color: Theme.violet) }
                        }
                        if !role.memberOf.isEmpty {
                            Text("Member of \(role.memberOf.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let until = role.validUntil {
                            Text("Valid until \(until)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Grant…") {
                        grantRole = role.name
                    }
                    .controlSize(.small)
                    .help("Use this role in the GRANT / REVOKE builder below")
                }
                .padding(.vertical, 3)
            }
        }
        .listStyle(.inset)
    }

    private var grantForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GRANT / REVOKE")
                .font(.subheadline.weight(.semibold))
            HStack {
                Picker("Privilege", selection: $grantPrivilege) {
                    ForEach(privileges, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
                Text("ON")
                    .foregroundStyle(.secondary)
                TextField("target", text: $grantTarget, prompt: Text("TABLE public.users"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Text("TO")
                    .foregroundStyle(.secondary)
                TextField("role", text: $grantRole, prompt: Text("role"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 150)
            }
            HStack {
                Button("Grant") { Task { await runGrant(isRevoke: false) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canGrant)
                Button("Revoke") { Task { await runGrant(isRevoke: true) } }
                    .disabled(!canGrant)
                Spacer()
                if let grantResult {
                    Text(grantResult)
                        .font(.caption)
                        .foregroundStyle(grantResult.hasPrefix("Failed") ? Color.red : Color.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func runGrant(isRevoke: Bool) async {
        let action = isRevoke ? "REVOKE" : "GRANT"
        let onClause = grantTarget.trimmingCharacters(in: .whitespaces)
        let role = grantRole.trimmingCharacters(in: .whitespaces)
        // `onClause` is user-typed free text; we intentionally don't quote it
        // because the user controls keywords like SCHEMA / TABLE that must
        // appear unquoted. Role name gets quoted to be safe.
        let sql = isRevoke
            ? "\(action) \(grantPrivilege) ON \(onClause) FROM \(quoteIdent(role))"
            : "\(action) \(grantPrivilege) ON \(onClause) TO \(quoteIdent(role))"
        switch await appVM.performRowMutation(sql: sql) {
        case .success:
            grantResult = "\(action) executed."
        case let .foreignKeyViolation(msg), let .error(msg):
            grantResult = "Failed: \(msg)"
        }
    }

    @MainActor
    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            roles = try await appVM.dbClient.listRoles()
        } catch {
            appVM.errorMessage = error.localizedDescription
        }
    }
}
