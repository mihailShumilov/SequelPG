# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |

## Reporting a Vulnerability

If you discover a security vulnerability in SequelPG, please report it responsibly.

**Do not open a public GitHub issue for security vulnerabilities.**

Instead, please send an email to: **security@sequelpg.example.com**

Include the following in your report:
- Description of the vulnerability.
- Steps to reproduce the issue.
- Potential impact.
- Suggested fix (if any).

### What to Expect

- Acknowledgement of your report within 48 hours.
- An assessment of the vulnerability within 5 business days.
- A fix or mitigation plan communicated to you before public disclosure.

## Security Practices

- Passwords are stored exclusively in the macOS Keychain.
- Credentials are never logged or persisted in UserDefaults.
- All table and schema identifiers in generated SQL are quoted to prevent injection.
- User-supplied SQL in the Query tab is executed as-is (by design) with timeout and row limits applied.
