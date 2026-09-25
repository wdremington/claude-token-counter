# Security policy

## Reporting a vulnerability

Please **do not open a public issue** for security problems. Report them
privately through GitHub's
[private vulnerability reporting](https://github.com/wdremington/claude-token-counter/security/advisories/new).

Include what you found, how to reproduce it, and the version affected. You should
get an acknowledgement within a week.

## Supported versions

Only the latest release receives fixes.

## Scope

TokenCounter reads Claude Code session logs locally. Of particular interest:

- Anything that causes data from the logs (prompts, paths, usage) to leave the machine
- Parsing of untrusted log or pricing-catalog content (crashes, injection into exports)
- The code-signing and release pipeline
