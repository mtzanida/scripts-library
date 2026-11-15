# Scripts Library

A small collection of Python scripts for AWS cleanup and value sanitization.

## Why the deletion scripts exist

These scripts were created after a Terraform cleanup left resources behind in AWS. Resources were intended for deletion, but had not actually been removed when the next `terraform apply` ran. Recreating the infrastructure then failed because the previous resources or their dependencies still existed.

In AWS Secrets Manager, deleting a secret with a recovery window **schedules it for deletion** rather than removing it immediately. While the secret is pending deletion, Terraform cannot create another secret with the same name. The secrets cleanup script requests permanent deletion without a recovery window so that the name can become available again.

For API Gateway, the issue is leftover REST APIs and base path mappings that can block deletion or conflict with the infrastructure Terraform is trying to create. The API cleanup script removes mappings first, then requests deletion of the REST APIs. API Gateway does not use the same scheduled-deletion recovery window as Secrets Manager, and this script does not check for a pending-deletion status.

Use these scripts to resolve a confirmed cleanup problem before retrying `terraform apply`. They are manual cleanup tools, not a required step for every Terraform deployment. Check that AWS has finished deleting the resources before applying again; deletion can take time even after a successful API response.

## Available scripts

| Script | Purpose | Current scope |
| --- | --- | --- |
| [delete_secrets.py](Deletion/delete_secrets.py) | Requests permanent deletion of a Secrets Manager secret using `ForceDeleteWithoutRecovery=True`. | The hardcoded secret `test-secrets` in `eu-central-2`. |
| [delete_api.py](Deletion/delete_api.py) | Removes API Gateway base path mappings, then deletes REST APIs. | All domains, mappings, and REST APIs returned by its list calls in the selected account and `eu-central-2`; it does not filter by Terraform ownership or deletion status. |
| [sanitize_rego_values.py](Sanitization/sanitize_rego_values.py) | Produces a deterministic short value from the last eight characters of a SHA-256 hash. | Runs an example using the string `ERROR`. |

## Running the AWS cleanup scripts

1. Install Python 3 and the AWS SDK:

   ```bash
   python3 -m pip install boto3
   ```

2. Configure an AWS profile with permissions to inspect and delete the intended resources. If using IAM Identity Center / SSO, sign in:

   ```bash
   aws sso login --profile YOUR_PROFILE
   ```

3. Review the target AWS account and the hardcoded region in the script. For secrets, replace `test-secrets` with the intended secret name before running it.

   **Deletion is destructive.** Secret deletion has no recovery window. The API script attempts broad cleanup of the REST APIs and mappings returned by its list calls, including resources that may still be in use. Neither script provides a dry run or confirmation prompt. The API list calls are not paginated, so the script may not remove every resource in a larger account.

4. From the repository root, run only the script needed for the confirmed cleanup issue:

   ```bash
   python3 Deletion/delete_secrets.py YOUR_PROFILE
   ```

   or:

   ```bash
   python3 Deletion/delete_api.py YOUR_PROFILE
   ```

5. Inspect the output and verify the resources are gone in AWS before retrying `terraform apply`. Both scripts catch deletion exceptions and print failures, so a successful process exit alone does not confirm that cleanup succeeded. If cleanup removed resources still tracked by Terraform, review the next Terraform plan before applying.

## Running the sanitization example

This script uses only Python's standard library:

```bash
python3 Sanitization/sanitize_rego_values.py
```
