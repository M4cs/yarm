# Homebrew tap setup for `M4cs/homebrew-yarm`

This is a one-time setup for the tap repo. The main `M4cs/yarm` repo holds the
canonical `Formula/yarm.rb`; the tap repo just needs a copy of it.

## 1. Create the tap repo

```sh
gh repo create M4cs/homebrew-yarm --public \
  --description "Homebrew tap for yarm — uniform window corner radius on macOS Tahoe"
cd $(mktemp -d) && gh repo clone M4cs/homebrew-yarm && cd homebrew-yarm
mkdir -p Formula
```

Brew expects the formula at `Formula/<name>.rb` inside a repo named
`homebrew-<tapname>`. Both naming conventions are required.

## 2. Add the formula

```sh
curl -O https://raw.githubusercontent.com/M4cs/yarm/main/Formula/yarm.rb
git add Formula/yarm.rb
git commit -m "Initial formula"
git push
```

## 3. Verify the tap end-to-end

```sh
brew tap M4cs/yarm
brew install yarm
yarm --version
yarm install && yarm start
```

If brew complains it can't find a bottle, that's expected — the formula
builds from source. The `Cargo.lock` and `make` build steps run during
`brew install`.

## 4. Bumping for a new release

Tag the main repo (`git tag v0.1.1 && git push --tags`). The
`.github/workflows/release.yml` workflow runs on tag push, builds the
artifacts, computes the SHA256 of the auto-generated source tarball, and
prints the stanza you need:

```ruby
url "https://github.com/M4cs/yarm/archive/refs/tags/v0.1.1.tar.gz"
sha256 "<computed>"
version "0.1.1"
```

Paste those three lines over the existing `url` / `sha256` / `version` in
`M4cs/homebrew-yarm/Formula/yarm.rb`, commit, push. Users get the new build
on `brew upgrade yarm`.

## Optional: auto-bump on release

If you want zero manual steps, extend `.github/workflows/release.yml` to push
the formula update directly. You'd need:

- A PAT with `repo` scope on `M4cs/homebrew-yarm`, stored as
  `HOMEBREW_TAP_TOKEN` in `M4cs/yarm`'s repo secrets.
- A second job in the workflow that checks out the tap, rewrites `Formula/yarm.rb`
  with the new url/sha/version (e.g. via `sed`), commits, and pushes.

This is left out of the default workflow to keep the surface area small —
paste-bump is fine for a low-frequency project.
