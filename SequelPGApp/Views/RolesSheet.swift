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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Roles").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()

            HStack {
                TextField("Search roles…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Button { Task { await reload() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh list")
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            if isLoading {
                ProgressView().padding()
                Spacer()
            } else {
                rolesList
                Divider()
                grantForm
            }
        }
        .frame(width: 640, height: 560)
        .task { await reload() }
    }

    private var rolesList: some View {
        List {
            ForEach(filtered) { role in
                HStack(alignment: .top) {
                    Image(systemName: role.canLogin ? "person.fill" : "person.crop.circle")
                        .foregroundStyle(role.canLogin ? Color.accentColor : Color.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(role.name).font(.callout.weight(.medium))
                            if role.isSuperuser { badge("SUPERUSER", Color.red) }
                            if !role.canLogin { badge("NOLOGIN", Color.secondary) }
                            if role.canCreateDB { badge("CREATEDB", Color.blue) }
                            if role.canCreateRole { badge("CREATEROLE", Color.blue) }
                            if role.isReplication { badge("REPLICATION", Color.purple) }
                        }
                        if !role.memberOf.isEmpty {
                            Text("Member of: \(role.memberOf.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let until = role.validUntil {
                            Text("Valid until: \(until)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Grant") {
                        grantRole = role.name
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 3)
            }
        }
        .listStyle(.plain)
    }

    private var grantForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GRANT / REVOKE").font(.subheadline).fontWeight(.medium)
            HStack {
                Picker("Privilege:", selection: $grantPrivilege) {
                    ForEach(privileges, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 240)
                TextField("ON target (e.g. SCHEMA public, TABLE public.users)", text: $grantTarget)
                    .textFieldStyle(.roundedBorder)
                TextField("TO role", text: $grantRole)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
            HStack {
                Button("GRANT") { Task { await runGrant(isRevoke: false) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(grantTarget.trimmingCharacters(in: .whitespaces).isEmpty
                              || grantRole.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("REVOKE") { Task { await runGrant(isRevoke: true) } }
                    .disabled(grantTarget.trimmingCharacters(in: .whitespaces).isEmpty
                              || grantRole.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                if let grantResult {
                    Text(grantResult).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }

    @ViewBuilder
    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(.rect(cornerRadius: 3))
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
        case .foreignKeyViolation(let msg), .error(let msg):
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
