# Changelog

## 0.3.0

- Added global context defaults for new local Codex conversations. Startup opens global mode and respects CODEX_HOME; project overrides remain available.
- Fixed false configuration conflicts caused by context-key and managed-marker examples inside TOML strings, including multiline basic and literal strings. Unterminated strings and malformed real markers remain read-only.
- Preserved BOM, line endings, and unrelated configuration bytes across apply, repeat apply, and Auto removal, with new global and project regression coverage.
- Hardened session reload, preview, and external-change handling, plus release packaging and verification.
- Fixed Windows PowerShell 5.1 release lookup so a missing Release can be published while authentication and service errors still stop publication.
- Scoped CI privacy checks to the tested commit history and upgraded artifact upload/download actions to Node.js 24 versions.

Global settings provide client defaults; existing tasks are not rewritten, and higher-priority configuration or service limits may still take precedence. Restart an already-running Codex client before creating a new task when needed.
