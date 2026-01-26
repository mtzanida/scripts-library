# IAM Unused Roles Scanner

Scans for unused and inactive IAM roles across multiple AWS accounts using aws_login integration.

## Features

- Scans IAM roles across all accessible AWS accounts
- Identifies roles based on last used timestamp
- Configurable inactivity threshold (default: 90 days)
- Generates CSV report with findings
- Provides summary statistics

## Prerequisites

- AWS CLI v2
- jq
- awslogin command installed and configured
- Valid AWS SSO session (run `awslogin` first to authenticate)

## Usage

```bash
# First, authenticate with AWS SSO
awslogin

# Then run the scanner
./scan_unused_iam_roles.sh

# Custom threshold (e.g., 60 days)
INACTIVE_THRESHOLD_DAYS=60 ./scan_unused_iam_roles.sh

# Custom output directory
OUTPUT_DIR=/path/to/reports ./scan_unused_iam_roles.sh
```

## Output

The script generates a CSV file in `./reports/` with:
- Account ID and Name
- Role Name
- Last Used Date
- Days Inactive

Summary statistics include:
- Total roles scanned
- Number of inactive roles
- Percentage of inactive roles

## Recommendations

Roles marked as inactive should be reviewed for:
- Potential deletion if no longer needed
- Documentation of purpose if intentionally unused
- Rotation or consolidation opportunities
