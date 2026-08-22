## Summary

What changed and why?

## Security impact

Describe any effect on file containment, symlink behavior, Git safety mode, command execution, process lifecycle, HTTP/MCP validation, credentials, or vendored binaries. Write `None` when not applicable.

## Verification

List the exact commands run and their results.

## Checklist

- [ ] I inspected the existing owner/callers/tests before changing behavior.
- [ ] I did not commit secrets, credentials, local stores, or generated build output.
- [ ] I added or updated tests for behavior changes.
- [ ] I ran relevant Swift typecheck/tests/build checks.
- [ ] I updated vendored dependency provenance/checksums if applicable.
- [ ] I kept unrelated refactors out of this change.
