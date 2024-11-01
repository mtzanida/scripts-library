import sys

import boto3
from botocore.config import Config

my_config = Config(
    region_name="eu-central-2",
    signature_version="v4",
    retries={"max_attempts": 10, "mode": "standard"},
)

# Get the name of the AWS profile from the first argument
aws_profile = sys.argv[1]

# Create a session using SSO
session = boto3.Session(profile_name=aws_profile)

# Create Secrets Manager client
secrets_manager_client = session.client("secretsmanager", config=my_config)


def delete_specific_secret(secret_name):
    try:
        # Delete the secret
        secrets_manager_client.delete_secret(
            SecretId=secret_name, ForceDeleteWithoutRecovery=True
        )
        print(f"Secret '{secret_name}' deleted successfully.")
    except Exception as e:
        print(f"Failed to delete secret '{secret_name}': {str(e)}")


if __name__ == "__main__":
    # Replace 'your_secret_name' with the name of the secret you want to delete
    delete_specific_secret("test-secrets")
