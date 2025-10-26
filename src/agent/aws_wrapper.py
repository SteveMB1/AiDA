from __future__ import annotations

from typing import Dict, List, Optional

import aioboto3
import yaml


async def get_aws_instances(region: str, filters: Optional[Dict[str, str]] = None) -> Dict[str, List[Dict]]:
    """
    Asynchronously retrieve AWS EC2 instances in the specified region, optionally filtering by tags.

    :param region: AWS region to query (e.g., 'us-west-2').
    :param filters: Optional dict of tag filters, where keys are tag names and values are tag values.
    :return: Dictionary mapping Program tag values to lists of instance information dicts.
    """
    print(f"AWS is configured to call on region: {region}")

    # Initialize an aioboto3 session for async EC2 client
    session = aioboto3.Session()
    async with session.client("ec2", region_name=region) as ec2:
        # Convert the supplied tag filters to AWS EC2 filter objects
        ec2_filters = [
            {"Name": f"tag:{key}", "Values": [value]}
            for key, value in (filters or {}).items()
        ]

        # Build kwargs to conditionally include the Filters parameter
        describe_kwargs = {"Filters": ec2_filters} if ec2_filters else {}

        # Asynchronously call describe_instances
        response = await ec2.describe_instances(**describe_kwargs)

        instance_dict: Dict[str, List[Dict]] = {}

        # Process the response to build our instance dictionary
        for reservation in response.get("Reservations", []):
            for instance in reservation.get("Instances", []):
                instance_obj = {
                    "InstanceId": instance["InstanceId"],
                    "InstanceType": instance["InstanceType"],
                    "Region": region,
                    "State": instance["State"]["Name"],
                    "Provider": "AWS",
                    # Primary private IP address
                    "PrivateIpAddress": instance.get("PrivateIpAddress"),
                    "LaunchTime": instance["LaunchTime"],
                    "Tags": {},
                }

                # Add public IP if available
                public_ip = instance.get("PublicIpAddress")
                if public_ip:
                    instance_obj["PublicIpAddress"] = public_ip

                # Collect all tags and group by Program tag
                for tag in instance.get("Tags", []):
                    key = tag.get("Key")
                    value = tag.get("Value")
                    instance_obj["Tags"][key] = value

                    if key == "Program":
                        program_key = value
                        instance_dict.setdefault(program_key, []).append(instance_obj)

        return instance_dict


def update_yaml_tags(env_value: str, project_value: str, regions: list, program: str, path: str):
    """
    Create or overwrite a YAML file with the specified AWS EC2 dynamic inventory structure.

    Parameters:
    - env_value: New value for filters.tag:Environment.
    - project_value: New value for filters.tag:Project.
    - regions: List of AWS regions.
    """

    file_path = f"{path}/aws_ec2.yaml"

    data = {
        'plugin': 'aws_ec2',
        'keyed_groups': [
            {
                'key': 'tags',
                'prefix': 'tag'
            }
        ],
        'regions': regions,
        'filters': {
            'tag:Environment': env_value,
            'tag:Project': project_value,
            'tag:Program': program
        },
        'compose': {
            'ansible_host': 'private_ip_address'
        },
        'hostnames': ['private-ip-address']
    }

    with open(file_path, 'w') as f:
        yaml.safe_dump(data, f, sort_keys=False)
