# Contributing to SequelPG

Thank you for your interest in contributing to SequelPG.

## Getting Started

1. Fork the repository.
2. Clone your fork locally.
3. Open the project in Xcode 15+ (`open SequelPG.xcodeproj`).
4. Build and run to verify everything works.

## Branch Naming

Use the following prefixes:

| Prefix      | Use Case             |
| ----------- | -------------------- |
| `feat/`     | New features         |
| `fix/`      | Bug fixes            |
| `refactor/` | Code refactoring     |
| `test/`     | Adding/fixing tests  |
| `docs/`     | Documentation only   |
| `chore/`    | Tooling, CI, config  |

Example: `feat/add-query-history`

## Commit Messages

We follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>: <short description>

[optional body]
```

Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`

Examples:
- `feat: add query execution timeout`
- `fix: prevent crash on nil column value`
- `refactor: extract connection validation logic`

## Code Style

We use **SwiftFormat** for consistent code formatting.

### Running the Formatter

```bash
# Format all Swift files
./Scripts/format.sh

# Or run directly
swiftformat SequelPGApp/ SequelPGTests/ --config .swiftformat
```

### Pre-commit Hook (Optional)

Install the pre-commit hook to auto-format before each commit:

```bash
cp Scripts/pre-commit .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```

## Pull Request Guidelines

1. Create a branch from `main` with the appropriate prefix.
2. Make small, focused commits.
3. Ensure the project builds without warnings.
4. Run the formatter before submitting.
5. Add tests for new functionality.
6. Open a pull request with a clear description of changes.

## Architecture

- **MVVM** pattern is strictly enforced.
- Views must not contain database calls.
- Only `PostgresClient` touches the database driver.
- Only `ConnectionStore` touches UserDefaults.
- Only `KeychainService` touches the Keychain.
