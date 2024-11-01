import hashlib


def sanitized(value):
    # Calculate the SHA-256 hash of the value
    hash_object = hashlib.sha256(value.encode())
    hash_value = hash_object.hexdigest()

    # Take the last 8 characters of the hash as the sanitized result
    sanitized_result = hash_value[-8:]

    return sanitized_result


# Example usage
original_value = "ERROR"
result = sanitized(original_value)

print(f"Original value: {original_value}")
print(f"Sanitized result: {result}")
