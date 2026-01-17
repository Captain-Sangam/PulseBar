# Contributing to PulseBar

First off, thank you for considering contributing to PulseBar! It's people like you that make PulseBar such a great tool for the AWS community.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [How Can I Contribute?](#how-can-i-contribute)
- [Development Setup](#development-setup)
- [Style Guidelines](#style-guidelines)
- [Commit Messages](#commit-messages)
- [Pull Request Process](#pull-request-process)
- [Community](#community)

## Code of Conduct

This project and everyone participating in it is governed by our [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code. Please report unacceptable behavior to the project maintainers.

## Getting Started

### Prerequisites

- macOS 13.0 or later
- Xcode 15+ or Swift 5.9+ toolchain
- AWS account with RDS instances (for testing)
- Git

### Quick Start

```bash
# Fork the repository on GitHub, then:
git clone https://github.com/YOUR_USERNAME/PulseBar.git
cd PulseBar

# Build and run
make run

# Or install for full functionality (notifications)
make install
```

## How Can I Contribute?

### 🐛 Reporting Bugs

Before creating bug reports, please check the existing issues to avoid duplicates.

**When reporting a bug, include:**

- Your macOS version
- Swift version (`swift --version`)
- Steps to reproduce the issue
- Expected behavior vs actual behavior
- Screenshots if applicable
- Relevant log output (run from terminal to see logs)

**Use the bug report template** when creating a new issue.

### 💡 Suggesting Features

We love feature suggestions! Please:

1. Check if the feature is already on our [Roadmap](README.md#roadmap)
2. Search existing issues to see if it's been suggested
3. Open a new issue with the "feature request" template
4. Describe the use case and why it would be valuable

### 📝 Improving Documentation

Documentation improvements are always welcome:

- Fix typos or clarify existing docs
- Add examples or tutorials
- Improve code comments
- Update the README or agents.md

### 🔧 Contributing Code

#### Good First Issues

Look for issues labeled `good first issue` - these are great for newcomers!

#### Areas We'd Love Help With

- [ ] Parameter group querying for accurate `max_connections`
- [ ] Historical metric graphs
- [ ] Performance Insights integration
- [ ] Multi-account support
- [ ] Custom alert thresholds
- [ ] Unit tests
- [ ] UI improvements

## Development Setup

### 1. Fork and Clone

```bash
# Fork on GitHub, then:
git clone https://github.com/YOUR_USERNAME/PulseBar.git
cd PulseBar
git remote add upstream https://github.com/ORIGINAL_OWNER/PulseBar.git
```

### 2. Create a Branch

```bash
git checkout -b feature/your-feature-name
# or
git checkout -b fix/bug-description
```

### 3. Set Up AWS Credentials

You'll need AWS credentials for testing:

```bash
# ~/.aws/credentials
[default]
aws_access_key_id = YOUR_KEY
aws_secret_access_key = YOUR_SECRET
```

Required IAM permissions:
- `rds:DescribeDBInstances`
- `cloudwatch:GetMetricData`

### 4. Build and Test

```bash
# Debug build
make run

# Release build
make build

# Install (enables notifications)
make install

# Clean
make clean
```

### 5. Run the App

```bash
# Development (no notifications)
swift run

# Production (with notifications)
# Note: First time may need: xattr -cr /Applications/PulseBar.app
open /Applications/PulseBar.app
```

## Style Guidelines

### Swift Code Style

- Follow [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/)
- Use meaningful variable and function names
- Keep functions focused and small
- Add comments for "why", not "what"

```swift
// Good: Explains why
// Use 1-hour window because CloudWatch may not report storage metrics frequently
let startTime = now.addingTimeInterval(-3600)

// Bad: Explains what (obvious from code)
// Subtract 3600 from now
let startTime = now.addingTimeInterval(-3600)
```

### Code Organization

```swift
class MyService {
    // MARK: - Public Properties
    var publicProperty: String
    
    // MARK: - Public Methods
    func publicMethod() { }
    
    // MARK: - Private Properties
    private var privateProperty: Int
    
    // MARK: - Private Methods
    private func privateHelper() { }
}
```

### AWS SDK Usage

Always use namespaced types for CloudWatch:

```swift
// Correct
CloudWatchClientTypes.MetricDataQuery
CloudWatchClientTypes.Dimension

// Incorrect (may conflict with Foundation)
MetricDataQuery
Dimension
```

### Error Handling

- Use `do-catch` with logging
- Never crash on recoverable errors
- Continue processing other items if one fails

```swift
for instance in instances {
    do {
        let metrics = try await fetchMetrics(for: instance)
        // ...
    } catch {
        print("Error fetching metrics for \(instance.identifier): \(error)")
        // Continue with other instances
    }
}
```

### UI Updates

Always update UI on the main thread:

```swift
Task {
    await monitoringService.refresh()
    await MainActor.run {
        updateMenu()
    }
}
```

## Commit Messages

We follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

[optional body]

[optional footer]
```

### Types

- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation only
- `style`: Code style (formatting, semicolons, etc.)
- `refactor`: Code change that neither fixes a bug nor adds a feature
- `perf`: Performance improvement
- `test`: Adding or updating tests
- `chore`: Maintenance tasks

### Examples

```
feat(metrics): add read IOPS metric

fix(storage): handle missing CloudWatch data gracefully

docs(readme): update installation instructions

refactor(alerts): extract deduplication logic to separate method
```

## Pull Request Process

### Before Submitting

1. **Update your branch** with the latest upstream changes:
   ```bash
   git fetch upstream
   git rebase upstream/main
   ```

2. **Test your changes**:
   - Build succeeds: `make build`
   - App runs without errors
   - Test with actual AWS RDS instances if possible

3. **Check for issues**:
   - No hardcoded credentials
   - No debug `print` statements (except for errors)
   - Code follows style guidelines

### Submitting

1. Push your branch to your fork
2. Open a Pull Request against `main`
3. Fill out the PR template completely
4. Link any related issues

### PR Review

- A maintainer will review your PR
- Address any requested changes
- Once approved, a maintainer will merge

### After Merge

- Delete your branch
- Pull the latest main
- Celebrate! 🎉

## Testing

### Manual Testing Checklist

- [ ] App launches without errors
- [ ] Menu bar icon appears
- [ ] Profile selector works
- [ ] Region selector works
- [ ] RDS instances are fetched
- [ ] Metrics display correctly
- [ ] Color coding is correct
- [ ] Refresh button works
- [ ] Auto-refresh works (wait 15 minutes or modify timer)
- [ ] Alerts trigger when metrics exceed 50% (requires `make install`)

### Test Scenarios

1. **No credentials**: Remove `~/.aws/credentials` and verify graceful handling
2. **Invalid credentials**: Use fake credentials and verify error handling
3. **No RDS instances**: Use a region with no instances
4. **Many instances**: Test with 50+ RDS instances if possible
5. **Network issues**: Disconnect network during refresh

## Security

- **Never commit credentials** - AWS keys, secrets, or tokens
- **Never log credentials** - Even in debug mode
- **Report security vulnerabilities** - See our [Security Policy](SECURITY.md) for reporting guidelines

## Community

### Getting Help

- 📖 Read the [README](README.md) and [agents.md](agents.md)
- 🔍 Search existing [issues](../../issues)
- 💬 Open a new issue for questions

### Recognition

Contributors are recognized in:
- GitHub contributors page
- Release notes (for significant contributions)

---

Thank you for contributing to PulseBar! 🎉
