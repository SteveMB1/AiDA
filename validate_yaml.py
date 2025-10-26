# python3 validate_yaml.py example.yaml

import yaml
import sys

def is_valid_yaml(file_path):
    """Checks if a given YAML file is valid."""
    try:
        with open(file_path, 'r', encoding='utf-8') as file:
            yaml.safe_load(file)
        print(f"✅ The file '{file_path}' is a valid YAML file.")
        return True
    except yaml.YAMLError as e:
        print(f"❌ Invalid YAML file: {file_path}")
        print(f"Error details:\n{e}")
        return False
    except FileNotFoundError:
        print(f"❌ File not found: {file_path}")
        return False
    except Exception as e:
        print(f"❌ An unexpected error occurred: {e}")
        return False

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python validate_yaml.py <path_to_yaml_file>")
    else:
        is_valid_yaml(sys.argv[1])
