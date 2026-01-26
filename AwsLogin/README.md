# AWS Login Script

AWS SSO login script with interactive account and role selection.

## Setup

1. Copy `.env.example` to `.env`:
   ```bash
   cp .env.example .env
   ```

2. Edit `.env` and set your SSO start URL:
   ```bash
   SSO_START_URL=https://your-sso-url.awsapps.com/start#
   ```

3. Source the environment variables before running:
   ```bash
   source .env
   ./aws_login.sh
   ```

## Usage

```bash
./aws_login.sh [OPTIONS] [FILTER]
```

Options:
- `--profile PROFILE`: Use specified AWS profile (default: default)
- `--role ROLE`: Pre-select role (fuzzy matching)
- `--help, -h`: Show help message

Examples:
```bash
./aws_login.sh                      # Interactive login
./aws_login.sh prod                 # Filter accounts containing 'prod'
./aws_login.sh --role operator      # Pre-select role
```
