# Releasing Pip

Every release becomes an update that everyone's Pip offers within a few hours.

```sh
git commit -am "What you changed"
./release.sh 1.1.0 "Short note on what's new"
```

`release.sh` stamps the version, builds the universal app, signs it with the **Pip Buddy** key, and stops if the build contains a file path, user name or email address. Then it tags the commit, pushes it, and publishes `Pip.zip` as a GitHub release.

## The Pip Buddy signing key

Releases are signed with a self-signed key named "Pip Buddy". It costs nothing and carries no personal details. It does two jobs:

- macOS keeps each user's Accessibility permission across updates, because every release has the same signer.
- Pip installs an update only if it's signed with the same key, so a tampered download is refused.

It doesn't make macOS trust Pip on first launch; that needs a paid Apple Developer ID. So new users click **Open Anyway** once (see the README).

**Keep the key safe.** It lives in the login keychain of the Mac that makes releases. A password-protected backup is outside this repo, in `~/Library/Application Support/PipBuddy/signing/`, together with its password. Copy that folder somewhere safe, like a password manager. If the key is lost, a new one works, but everyone has to re-allow Accessibility once and install that release by hand, since their Pip won't accept a different signer.

To use the key on another Mac, double-click the `.p12` backup to import it into the login keychain.

Never commit the key, the `.p12` file or its password. `.gitignore` blocks `*.p12` and `*.cer`.
