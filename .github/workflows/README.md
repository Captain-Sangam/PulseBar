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

**Requirements:**
- Runs on `macos-latest` runner
- Uses Xcode's built-in Swift
- No secrets required

## Local Testing

Before pushing, test locally:

```bash
# Same as PR workflow
swift build -v
swift build -c release -v
swift test || echo "No tests"
```

## Troubleshooting

### Build Failures

**Issue:** Dependencies fail to resolve
- Check `Package.swift` for correct AWS SDK version
- Run `swift package resolve` locally first

**Issue:** Swift version mismatch
- The workflow uses Xcode's built-in Swift
- Ensure code is compatible with Swift 5.9+
