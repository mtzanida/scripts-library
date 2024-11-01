import sys

import boto3
from botocore.config import Config

# Set up config required for the boto3 client
my_config = Config(
    region_name="eu-central-2",
    signature_version="v4",
    retries={"max_attempts": 10, "mode": "standard"},
)

# Get the name of the AWS profile from the first argument
aws_profile = sys.argv[1]

# Create a session using SSO
session = boto3.Session(profile_name=aws_profile)

# Create API Gateway client
api_gateway_client = session.client("apigateway", config=my_config)


def remove_all_api_mappings():
    # Get all the API mappings
    api_mappings = api_gateway_client.get_domain_names()

    # Iterate through the mappings and delete them
    for domain in api_mappings["items"]:
        mappings = api_gateway_client.get_base_path_mappings(
            domainName=domain["domainName"]
        )
        for mapping in mappings["items"]:
            try:
                # Delete the mapping
                api_gateway_client.delete_base_path_mapping(
                    domainName=domain["domainName"], basePath=mapping["basePath"]
                )
                print(
                    f"API mapping with basePath {mapping['basePath']} removed successfully."
                )
            except Exception as e:
                print(f"Failed to remove API mapping: {str(e)}")


def clear_api_gateway():
    # List all the APIs in the API Gateway
    apis = api_gateway_client.get_rest_apis()

    # Iterate through the APIs and delete them
    for api in apis["items"]:
        api_id = api["id"]
        api_name = api["name"]
        try:
            # Delete the API
            api_gateway_client.delete_rest_api(restApiId=api_id)
            print(f"API Gateway '{api_name}' (ID: {api_id}) deleted successfully.")
        except Exception as e:
            print(f"Failed to delete API Gateway '{api_name}': {str(e)}")


if __name__ == "__main__":
    remove_all_api_mappings()
    clear_api_gateway()
