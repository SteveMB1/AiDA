#!/usr/bin/env python3.9

import socket

import requests
from ansible.module_utils.basic import AnsibleModule


def get_cluster_shard_limit(uri):
    # include_defaults=true makes Elasticsearch return even the default value
    url = f"{uri}/_cluster/settings?include_defaults=true"
    resp = requests.get(url)
    resp.raise_for_status()

    # parse the JSON payload
    data = resp.json()

    # the default lives under the "defaults" key, and is named "cluster.max_shards_per_node"
    defaults = data.get("defaults", {})
    limit = defaults['cluster']['max_shards_per_node']

    # make sure it's an int
    return int(limit)


def check_elasticsearch_index_health(uri):
    """
    Check if all Elasticsearch indices are in green state.

    Args:
        es_url (str): Base URL of the Elasticsearch server (e.g. http://localhost:9200)

    Returns:
        bool: True if all indices are green, False otherwise
    """
    try:
        response = requests.get(f"{uri}/_cat/indices?format=json")
        response.raise_for_status()
        indices = response.json()

        for index in indices:
            if index.get("health") != "green":
                return False
        return True

    except requests.RequestException as e:
        return False


def check_index_limit(uri, fqdn):
    """
    Check if the number of shards on this node is within 75% of max allowed.
    """
    try:
        response = requests.get(f"{uri}/_cat/shards?format=json")
        response.raise_for_status()
        shards = response.json()

        # Count shards on this specific node
        size = sum(1 for shard in shards if shard.get("node") == fqdn)

        max_shards_per_node = get_cluster_shard_limit(uri)

        # If the setting isn't defined (or is zero), we can't compute a percentage
        if not max_shards_per_node:
            return None

        percentage = round((size / max_shards_per_node) * 100)
        return percentage

    except requests.RequestException:
        return None


def main():
    module = AnsibleModule(
        argument_spec={
            "uri": {"type": "str", "required": True}
        },
        supports_check_mode=True,
    )

    host = socket.gethostname()
    es_url = module.params["uri"]

    result = {
        "elasticsearch": {
            "index_status": check_elasticsearch_index_health(es_url),
            "index_limit": check_index_limit(es_url, host)
        }
    }

    module.exit_json(changed=False, **result)


if __name__ == "__main__":
    main()
