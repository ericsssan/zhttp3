# Security Policy

## Supported Versions

zhttp3 is pre-release software (v0.x). Security fixes are applied to the
`main` branch only.

## Reporting a Vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Report security issues by email to **ericsssan@gmail.com** with the subject
line `[zhttp3] Security Vulnerability`.

Include:
- A description of the vulnerability and its potential impact
- Steps to reproduce or a proof-of-concept (if available)
- Any suggested mitigations

You will receive an acknowledgement within 72 hours. We aim to release a fix
within 14 days for confirmed vulnerabilities.

## Scope

In scope:
- Memory safety issues (buffer overflows, use-after-free, etc.)
- Incorrect QPACK/HTTP/3 parsing that could be exploited
- Denial-of-service via malformed input

Out of scope:
- Issues in dependencies (report upstream)
- Theoretical issues without a practical attack vector
