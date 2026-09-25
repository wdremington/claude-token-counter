# Contributing to TokenCounter

Thanks for your interest! Bug reports, ideas, and pull requests are welcome.

## Before you start

- For anything beyond a small fix, please open or comment on an
  [issue](https://github.com/wdremington/claude-token-counter/issues) first so we
  can agree on the approach.
- Security problems: see [SECURITY.md](SECURITY.md). Don't file them as public issues.

## Development setup

The native app lives in `TokenCounterMac/` and builds with the **Xcode Command
Line Tools alone**. A full Xcode install is not required, and the build must not
come to depend on one.

```sh
cd TokenCounterMac
swift build                          # debug build
.build/debug/TokenCounter --test     # run the self-test suite
./build.sh                           # assemble build/TokenCounter.app
```

The test suite lives in `Sources/TokenCounter/Support/SelfTest.swift` (not a
`testTarget`, since XCTest ships only with Xcode). New behaviour needs checks
there.

## Workflow

`main` is protected and always releasable. All changes, including the
maintainer's, go through a pull request.

1. Fork the repo (or, with write access, create a branch).
2. Name the branch after the change type: `feat/…`, `fix/…`, `docs/…`,
   `refactor/…`, `chore/…`.
3. Keep PRs focused on one change. Rebase on `main` rather than merging it in.
4. Open a PR using the template. CI must pass and the maintainer must approve
   before it can merge.

PRs are **squash-merged**, so the PR title becomes the commit message on
`main`. Titles must follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(pricing): import price lists from CSV
fix(export): show confirmation after Copy CSV
docs: explain model-id to price matching
```

Allowed types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`,
`build`, `ci`, `chore`, `revert`. Add `!` for breaking changes
(`feat!: …`). CI checks the title.

CI runs from forks only after the maintainer approves the run.

## Don't commit

- Claude Code or other assistant config (`CLAUDE.md`, `.claude/`). These are
  gitignored and stay local.
- Personal paths, internal URLs, credentials, or real usage data in tests,
  screenshots, or docs.

## Releases (maintainer)

The project uses [Semantic Versioning](https://semver.org/). `feat` means a
minor bump, `fix` a patch, and `!` a major.

1. On a `chore/release-X.Y.Z` branch: update `TokenCounterMac/VERSION`, move
   the `CHANGELOG.md` "Unreleased" entries under the new version, and open a PR.
2. After it merges, from an up-to-date `main`, run `./build.sh --release`,
   then tag and publish:
   ```sh
   git tag -a vX.Y.Z -m "vX.Y.Z" && git push origin vX.Y.Z
   gh release create vX.Y.Z build/TokenCounter-X.Y.Z.dmg --notes-from-tag
   ```
3. Update `Casks/tokencounter.rb` (version + sha256) in a follow-up
   `chore(cask): …` PR.

## License

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE).
