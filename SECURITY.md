# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.x.x   | :white_check_mark: |

## Reporting a Vulnerability

We take the security of PulseBar seriously. If you believe you have found a security vulnerability, please report it to us as described below.

### How to Report

**Please do NOT report security vulnerabilities through public GitHub issues.**

Instead, please report them via one of the following methods:

1. **GitHub Security Advisories**: Use the "Report a vulnerability" button in the Security tab of this repository (preferred method)

2. **Email**: Contact the maintainers directly (if email is provided in the repository)

3. **Private Issue**: Create a GitHub issue with `[SECURITY]` prefix and minimal details, then wait for maintainer contact

### What to Include

Please include the following information in your report:

- Type of vulnerability (e.g., credential exposure, injection, etc.)
- Full paths of source file(s) related to the vulnerability
- Step-by-step instructions to reproduce the issue
- Proof-of-concept or exploit code (if possible)
- Impact of the vulnerability

### Response Timeline

- **Initial Response**: Within 48 hours
- **Status Update**: Within 7 days
- **Resolution**: Depends on complexity, typically within 30 days

### What to Expect

1. We will acknowledge your report within 48 hours
2. We will investigate and keep you informed of our progress
3. We will work with you to understand and resolve the issue
4. Once fixed, we will publicly acknowledge your contribution (unless you prefer to remain anonymous)

## Security Best Practices for Users

### AWS Credentials

- **Never commit credentials** to version control
- Use IAM roles with minimal required permissions
- Rotate credentials regularly
- Use AWS session tokens when possible

### Required IAM Permissions

PulseBar only requires these read-only permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "rds:DescribeDBInstances",
      "cloudwatch:GetMetricData"
    ],
    "Resource": "*"
  }]
}
```

### Data Handling

- PulseBar does **not** store your AWS credentials
- Credentials are read from `~/.aws/credentials` on each request
- All data is kept in memory only (no persistence)
- No data is sent to third parties

## Security Features

- Read-only AWS access (cannot modify RDS instances)
- No credential caching or storage
- No network calls except to AWS APIs
- Runs locally on your machine

## Acknowledgments

We appreciate the security research community's efforts in helping keep PulseBar and its users safe.
