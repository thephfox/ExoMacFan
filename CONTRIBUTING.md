# Contributing to ExoMacFan

**Created by:** Douglas M. — Code PhFox ([www.phfox.com](https://www.phfox.com))  
**Date:** 2026-02-20  
**Purpose:** Guidelines for contributing to the ExoMacFan project

---

Thank you for your interest in contributing! ExoMacFan is a hardware-adjacent project — please read these guidelines carefully before submitting changes.

## Before You Start

- Check [open issues](https://github.com/thephfox/ExoMacFan/issues) to avoid duplicating effort.
- For large changes, open an issue first to discuss your approach.
- All contributors must follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Attribution Requirement

Any contribution you submit becomes part of a project licensed under the [MIT License with Attribution](LICENSE). By submitting a PR you agree that:

- Your contribution may be distributed under those terms.
- The original project credit — **Douglas M. — Code PhFox ([www.phfox.com](https://www.phfox.com))** — is preserved in all derivative works.

## Development Setup

**Requirements:** macOS 14+, Xcode Command Line Tools, Swift 5.9+

```bash
# Clone
git clone https://github.com/thephfox/ExoMacFan.git
cd ExoMacFan

# Build
./compile-swift.sh

# Run
open build/ExoMacFan.app
```

## Submitting Changes

1. Fork the repository.
2. Create a feature branch: `git checkout -b feat/my-feature`
3. Keep commits focused and descriptive.
4. Ensure `./compile-swift.sh` exits 0 with no new errors.
5. Open a Pull Request against `main`.

## Code Style

- Follow existing Swift naming conventions and file structure.
- Keep file headers consistent with the rest of the project (creator, date, description).
- Do not add third-party dependencies without prior discussion.

## Hardware Safety

ExoMacFan controls SMC fan speeds. PRs that modify fan control logic must:

- Not exceed hardware maximum RPM for any fan.
- Not remove or bypass existing safety guards in `FanController.swift`.
- Be clearly explained in the PR description with expected thermal behavior.

## Reporting Bugs

Use the GitHub Issues tracker. For **security issues**, see [SECURITY.md](SECURITY.md) — do not file a public issue.
