# GitHub Actions Workflows

This directory contains automated workflows for the PulseBar project.

## Workflows

### 1. PR Validation (`pr-validation.yml`)

**Triggers:**
- Pull requests to `main` or `develop` branches
- Pushes to `main` or `develop` branches

**Purpose:**
Validates code quality and buildability before merging.

**Steps:**
1. ✅ Checkout code
2. ✅ Set up Swift 5.9
3. ✅ Cache dependencies for faster builds
4. ✅ Resolve Swift package dependencies
5. ✅ Build debug configuration
6. ✅ Build release configuration
7. ✅ Run tests (if available)
8. ✅ Validate Package.swift structure
9. ✅ Security check for hardcoded credentials
10. ✅ Generate build summary

**Requirements:**
- Runs on macOS 13 runner
- No secrets required

**Example Output:**
```
✅ PR validation passed
- Swift version: Swift 5.9
- Platform: macOS 13+
- Configuration: Debug + Release builds validated
```

---

### 2. Build and Release (`release.yml`)

**Triggers:**
- GitHub release creation or publication

**Purpose:**
Automatically builds and attaches the app bundle to GitHub releases.

**Steps:**
1. ✅ Checkout code at release tag
2. ✅ Set up Swift 5.9
3. ✅ Cache dependencies
4. ✅ Resolve dependencies
5. ✅ Build release binary
6. ✅ Create `.app` bundle structure
7. ✅ Update version in Info.plist
8. ✅ Verify app bundle integrity
9. ✅ Create distributable ZIP archive
10. ✅ Generate SHA256 checksum
11. ✅ Upload artifacts to release

**Requirements:**
- Runs on macOS 13 runner
- Requires `contents: write` permission
- Uses `GITHUB_TOKEN` (automatically provided)

**Artifacts Produced:**
- `PulseBar-vX.X.X-macOS.zip` - The app bundle
- `PulseBar-vX.X.X-macOS.zip.sha256` - Checksum for verification

**Example Output:**
```
✅ Release build completed successfully

### Build Details
- Version: v1.0.0
- Swift version: Swift 5.9
- Platform: macOS 13+
- Architecture: arm64

### Artifacts
- PulseBar-v1.0.0-macOS.zip
- SHA256 checksum included
```

---

## Usage

### Creating a Release

To trigger the release workflow:

1. **Via GitHub UI:**
   - Go to Releases → Draft a new release
   - Create a tag (e.g., `v1.0.0`)
   - Fill in release notes
   - Click "Publish release"

2. **Via Git CLI:**
   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   
   # Then create release on GitHub
   gh release create v1.0.0 --title "v1.0.0" --notes "Release notes"
   ```

The workflow will automatically:
- Build the app
- Create a .app bundle
- Zip it
- Upload to the release

### Monitoring Workflows

- View workflow runs: Actions tab on GitHub
- Check build logs for errors
- Download build summaries from each run

### Local Testing

Before pushing, test locally:

```bash
# Validate build (same as PR workflow)
swift build -v
swift build -c release -v

# Test release creation (same as release workflow)
make install
```

---

## Troubleshooting

### Build Failures

**Issue:** Dependencies fail to resolve
- **Solution:** Check `Package.swift` for correct AWS SDK version
- **Solution:** Clear cache and retry

**Issue:** Swift version mismatch
- **Solution:** Update `swift-version` in workflow files
- **Solution:** Ensure code is compatible with Swift 5.9+

### Release Upload Failures

**Issue:** Asset upload fails
- **Solution:** Check `GITHUB_TOKEN` permissions
- **Solution:** Ensure release exists before upload

**Issue:** Wrong version in Info.plist
- **Solution:** Check tag format (must be `vX.X.X`)
- **Solution:** Verify sed command in release workflow

---

## Customization

### Change Swift Version

Edit both workflow files:

```yaml
- name: Set up Swift
  uses: swift-actions/setup-swift@v2
  with:
    swift-version: "5.10"  # Update here
```

### Add Code Signing

Add to release workflow after "Create .app bundle":

```yaml
- name: Sign app bundle
  env:
    SIGNING_IDENTITY: ${{ secrets.SIGNING_IDENTITY }}
  run: |
    codesign --force --deep --sign "$SIGNING_IDENTITY" \
      build/PulseBar.app
```

### Add Notarization

Add to release workflow after signing:

```yaml
- name: Notarize app
  env:
    APPLE_ID: ${{ secrets.APPLE_ID }}
    APPLE_PASSWORD: ${{ secrets.APPLE_PASSWORD }}
  run: |
    xcrun notarytool submit build/PulseBar.zip \
      --apple-id "$APPLE_ID" \
      --password "$APPLE_PASSWORD" \
      --wait
```

### Create DMG Instead of ZIP

Replace zip creation with:

```yaml
- name: Create DMG
  run: |
    hdiutil create -volname "PulseBar" -srcfolder build/PulseBar.app \
      -ov -format UDZO build/PulseBar.dmg
```

---

## Best Practices

1. **Always tag releases** with semantic versioning (`vX.Y.Z`)
2. **Write meaningful release notes** for users
3. **Test locally** before creating releases
4. **Monitor workflow runs** for failures
5. **Keep workflows updated** with latest actions versions

---

## Dependencies

### GitHub Actions Used

- `actions/checkout@v4` - Checkout repository
- `swift-actions/setup-swift@v2` - Set up Swift environment
- `actions/cache@v4` - Cache dependencies
- `actions/upload-release-asset@v1` - Upload to releases

### Runner Images

- `macos-13` - macOS 13 Ventura
  - Includes Xcode 15+
  - Swift 5.9+ support
  - Native Apple Silicon support

---

## Contributing

When modifying workflows:

1. Test changes in a fork first
2. Document any new steps
3. Update this README
4. Ensure backwards compatibility
5. Follow YAML best practices

---

**Last Updated:** 2026-01-17
