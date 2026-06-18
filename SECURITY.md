# Security Policy

Widen touches database credentials, schema metadata, generated SQL, and local
Keychain items. Please report security issues carefully.

## Supported Versions

The project is pre-1.0. Security fixes target the latest commit on `main` and
the latest public release when practical.

## Reporting A Vulnerability

Please do not open a public issue with exploit details, secrets, private schema
names, or real connection information.

Use GitHub private vulnerability reporting if it is available on the repository.
If it is not available, open a minimal public issue asking for a private
reporting channel and omit technical details until a maintainer responds.

Helpful private report details include:

- Affected Widen version or commit.
- macOS and Xcode version if relevant.
- Steps to reproduce with a minimal schema or mocked data.
- Whether the issue affects local mode, cloud mode, database execution,
  Keychain storage, update delivery, or release signing.
- Any known workaround.

## Security Boundaries

Important boundaries Widen aims to preserve:

- Database passwords and API keys stay in the macOS Keychain.
- Query results are not sent to model providers by Widen.
- Local mode should not send schema or prompts to a Widen backend.
- Generated SQL must be visible and reviewed before execution.
- SQL execution must continue through deterministic validation and database
  transaction limits.
- Release builds must remain signed, notarized, and Sparkle-verified.

App-level SQL checks are not a substitute for database permissions. Use
least-privilege Postgres roles, especially for production or shared databases.
