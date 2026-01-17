# GitHub Actions Workflows

## PR Validation (`pr-validation.yml`)

**Triggers:**
- Pull requests to `main` branch
- Pushes to `main` branch

**Purpose:**
Validates code quality and buildability before merging.

**Steps:**
1. Checkout code
2. Show Swift/Xcode versions
3. Cache Swift package dependencies
4. Resolve dependencies
5. Check code formatting
6. Build debug configuration
7. Build release configuration
8. Run tests (if available)
9. Validate Package.swift

---

## Build and Release (`release.yml`)

**Triggers:**
- GitHub release published

**Purpose:**
Automatically builds and attaches the app bundle to GitHub releases.

**Steps:**
1. Checkout code at release tag
2. Show Swift/Xcode versions
3. Cache dependencies
4. Resolve dependencies
5. Build release binary
6. Create `.app` bundle with icons
7. Update version in Info.plist
8. Verify app bundle
9. Create ZIP archive
10. Generate SHA256 checksum
11. Upload artifacts to release

**Artifacts Produced:**
- `PulseBar-vX.X.X-macOS.zip` - The app bundle
- `PulseBar-vX.X.X-macOS.zip.sha256` - Checksum for verification

**Note:** The app is not code-signed. Users will see "damaged" or "can't be opened" error.

**Users must run one of these after download:**
```bash
# Option 1: Remove quarantine flag
xattr -cr /Applications/PulseBar.app

# Option 2: Right-click app → Open → Click "Open"
```

---

## Requirements

Both workflows:
- Run on `macos-latest` runner
- Use Xcode's built-in Swift
- No secrets required (uses automatic `GITHUB_TOKEN`)

---

## Creating a Release

1. Go to **Releases** → **Draft a new release**
2. Create a tag (e.g., `v1.0.0`)
3. Fill in release notes
4. Click **Publish release**

The release workflow will automatically build and attach the app bundle.

---

## Local Testing

```bash
# Same as PR workflow
swift build -v
swift build -c release -v

# Same as release workflow
make install
```
