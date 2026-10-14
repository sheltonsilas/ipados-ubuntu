# Setup

Two audiences: the **owner** (sideloads the app, needs no programming) and a **future AI agent**
(tokens, builds, CI). Owner part first.

---

## For the owner

### Install the app

1. On the iPad, open <https://github.com/sheltonsilas/ipados-ubuntu/releases> in Safari.
2. Download `UbuntuPad-unsigned.ipa` — from the newest tagged release if there is one, otherwise
   from the rolling `nightly` release.
3. Sideload it with whichever you already use:
   - **AltStore / SideStore / Sideloadly** — they re-sign the app with your own certificate.
   - **TrollStore** — only on the iOS versions it supports (14.0–16.6.1, 16.7 RC, 17.0).
4. Enable **JIT** for the app before using it. Without JIT, emulation is unusably slow.
   - Easiest: install **StikDebug** on the same device and let it attach to UbuntuPad
     (the app must be installed with the `get-task-allow` entitlement, which our builds include).
   - Alternative: **TrollStore** can "launch with JIT" for apps that carry `get-task-allow`.
   - Later versions of this app will ship a built-in helper extension for this.
5. Launch the app. First launch downloads the Ubuntu image — expect a long wait.

### If something goes wrong

Open the app's **Diagnostics** screen, take a screenshot, and paste it into a new issue at
<https://github.com/sheltonsilas/ipados-ubuntu/issues>. The screen is designed to contain
everything an agent needs: iOS version, device model, page size, memory limit, whether JIT is
active, and the last error.

### What to tell the agent

- Which sideloading tool you used, and whether JIT turned on.
- How long the first launch took and how responsive the desktop feels.
- Screenshots or the text from the Diagnostics screen.

---

## For an AI agent

### Agent credentials

The agent authenticates with the GitHub CLI. The token lives in the operating system credential
store, **never** in this repository.

Check the current state:

```bash
gh auth status          # shows account and scopes, never the token value
gh api user --jq .login
```

If it is not authenticated (or the token was revoked), re-authenticate. The device flow needs the
owner to approve a code in the browser:

```bash
gh auth login --hostname github.com --git-protocol https \
  --scopes "public_repo,workflow" --web
```

Then, in the browser: open <https://github.com/login/device>, continue as the signed-in owner, and
enter the one-time code from the command output. If GitHub asks for **sudo-mode re-authentication**,
choose *Send a code via email* (or the authenticator app if the owner prefers) and complete it.

**Notes learned the hard way (2026-10-14):**

- The 8 code boxes on `github.com/login/device` must be filled **one character per box**; a
  scripted paste of the full code into the first box fails with `reason=not_found`.
- If the code entry fails once, `gh` may exit without storing a token — just rerun the login.
- Run the login so its output goes to a log file you can read, e.g.
  `yes "" | gh auth login --hostname github.com --git-protocol https --scopes "public_repo,workflow" --web > /tmp/gh-auth.log 2>&1 &`,
  then poll the log for `Authentication complete`.

### Token expiry and renewal

- The CLI token has **no fixed expiry**; it stays valid until revoked.
- Recorded expiry for the current credential: **none (revocable)**. Renewal = rerun `gh auth login`
  as above.
- If the owner ever wants a narrower credential, they can create a **fine-grained PAT** limited to
  this repository (Contents/Workflows/Actions/Issues/Pull requests read-write, Metadata read) at
  <https://github.com/settings/tokens?type=beta> and set it as `GH_TOKEN` in the agent's
  environment. Never paste that value into a chat message, issue, commit or file.
- Revoke anything suspicious at <https://github.com/settings/applications> (OAuth apps) and
  <https://github.com/settings/tokens>.

### CI secrets

None are needed. Workflows use the built-in `GITHUB_TOKEN`. Never add a third-party service
credential to this repository.

### Build and test

```bash
# Track B core: runs anywhere Swift does, and on ubuntu-latest in CI
cd track-b-runtime/core && swift test

# Repository layout checks
bash tools/check-layout.sh

# iOS app + unsigned IPA (macOS only; not available on the agent's Windows machine)
cd track-b-runtime
xcodegen generate --spec ios/project.yml
xcodebuild -project UbuntuPad.xcodeproj -scheme UbuntuPad -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
mkdir -p dist/Payload && cp -R build/Build/Products/Release-iphoneos/UbuntuPad.app dist/Payload/
(cd dist && zip -qry UbuntuPad-unsigned.ipa Payload)
```

Watch CI the same way the last session did:

```bash
gh run list --limit 5
gh run watch <run-id>
gh run view <run-id> --log-failed
```

### Entitlements and sideloading tools

Which entitlements survive which tool (Apple account-free paths only):

| Entitlement | AltStore / SideStore (free Apple ID) | Sideloadly | TrollStore |
| --- | --- | --- | --- |
| `get-task-allow` | Survives when the tool signs for development — this is what makes JIT attachable | Usually preserved | Supported |
| `com.apple.security.cs.allow-jit` | macOS Hardened Runtime entitlement; not what grants JIT on iOS | Same | Same |
| `dynamic-codesigning` | Not granted by a free Apple ID; banned on iOS 15+ / A12+ under TrollStore | Not granted | Banned on iOS 15+ A12+ |
| `com.apple.developer.kernel.increased-memory-limit` | Only with a paid developer account; absent for free-Apple-ID sideloading | Same | Can be preserved (check per version) |
| App extensions (needed by a helper-based JIT path) | Retained only if the tool signs them; verify per version | Retained | Retained |

Consequence for planning: **the debugger-attach JIT route (StikDebug / TrollStore) is the only one
we can rely on**, and the increased-memory-limit entitlement is not available on free-Apple-ID
installs. Verify each row against the tool's current docs before depending on it, and update this
table when a session learns more (with a source).

### Owner checklist (hand this to the owner, plain language)

1. Open the Releases page on the iPad and download the `.ipa`.
2. Install it with your usual sideloading tool.
3. Turn on JIT (StikDebug) for the app.
4. Launch it and give it time on first run.
5. If it does not work, screenshot the Diagnostics screen and open an issue.
