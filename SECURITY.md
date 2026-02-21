# Security Policy

**Created by:** Douglas M. — Code PhFox ([www.phfox.com](https://www.phfox.com))  
**Date:** 2026-02-20  
**Purpose:** Vulnerability disclosure and security reporting guidelines for ExoMacFan

---

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.0.x   | ✅ Yes    |

Only the latest release receives security fixes. Older versions are not backported.

## Scope

ExoMacFan interacts directly with macOS hardware via the SMC (System Management Controller) and a privileged helper daemon. Security concerns in scope include:

- Privilege escalation via the `ExoMacFanHelper` daemon
- Unauthorized SMC write access
- Local socket (`/tmp/exomacfan.sock`) tampering or spoofing
- LaunchDaemon (`com.exomacfan.helper`) injection or replacement

Out of scope: general macOS security issues unrelated to this app.

## Reporting a Vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Please report privately by contacting:

- **Website:** [www.phfox.com](https://www.phfox.com)

Include in your report:

1. A description of the vulnerability and its potential impact
2. Steps to reproduce
3. Any proof-of-concept code or screenshots (if applicable)
4. Your suggested fix (optional but appreciated)

**Response SLA:** I aim to acknowledge reports within **72 hours** and provide a resolution or mitigation within **14 days** for critical issues.

## Disclosure Policy

- Please give me reasonable time to investigate and patch before public disclosure.
- I will credit researchers who responsibly disclose valid vulnerabilities (unless anonymity is preferred).

## Hardware Risk Notice

> ExoMacFan modifies fan control hardware behavior. Misuse or vulnerabilities exploited in fan control could, in theory, affect thermal management. Use at your own risk. See [LICENSE](LICENSE) for the full hardware disclaimer.
