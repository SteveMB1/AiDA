#!/usr/bin/env python3.9
"""
RabbitMQ health-check Ansible module

• Keeps the existing metrics (long-running queues, time-to-drain, etc.).
• **NEW:** Flags any classic-mirrored queues that have one or more
  mirrors out of sync (i.e. the queue’s ``slave_nodes`` list is longer
  than its ``synchronised_slave_nodes`` list).

Outputs (excerpt)
-----------------
rabbitmq:
  is_high_queues: <bool>
  high_queues: [...]
  is_unsynchronized_mirrors: <bool>        #  <-- NEW
  unsynchronized_mirrors: [ {name, …} ]    #  <-- NEW
"""
import requests
from ansible.module_utils.basic import AnsibleModule


def get_queue_names(uri, username, password):
    """Return a list of all queue names in the default vhost."""
    try:
        response = requests.get(
            f"{uri}/queues", auth=(username, password), timeout=3000
        )
        response.raise_for_status()
        return [q["name"] for q in response.json()]
    except Exception as exc:  # pragma: no cover
        print(f"Error fetching queue list: {exc}")
        return []


def get_queues_stats(uri, username, password, targets):
    """
    Return per-queue details plus an `unsynchronized_mirrors` flag.

    For classic-mirrored queues:
        unsynchronized_mirrors == True
        ⇢ len(slave_nodes) > len(synchronised_slave_nodes)
    """
    result = []

    for name in targets:
        try:
            response = requests.get(
                f"{uri}/queues/%2F/{name}",
                auth=(username, password),
                timeout=3000,
            )
            response.raise_for_status()
            queue = response.json()

            stats = queue.get("message_stats", {})
            messages_ready = queue.get("messages_ready", 0)
            total_messages = queue.get("messages", 0)
            deliver_rate = stats.get("deliver_details", {}).get("rate", 0.0)

            # ——— time-to-drain calculation (unchanged) ———
            if deliver_rate > 0:
                time_to_complete_ms = (messages_ready / deliver_rate) * 1000
            elif messages_ready == 0:
                time_to_complete_ms = None
            elif deliver_rate == 0 and 0 < messages_ready < 300:
                time_to_complete_ms = 300_000
            else:
                time_to_complete_ms = 300_000

            # ——— mirror-sync detection ———
            slave_nodes = queue.get("slave_nodes", []) or []
            synced_nodes = queue.get("synchronised_slave_nodes", []) or []
            unsynced = len(slave_nodes) > len(synced_nodes)

            result.append(
                {
                    "name": queue.get("name"),
                    "total_messages": total_messages,
                    "messages": messages_ready,
                    "time_to_complete_ms": (
                        int(time_to_complete_ms)
                        if time_to_complete_ms is not None
                        else None
                    ),
                    "unsynchronized_mirrors": unsynced,
                    "slave_nodes": slave_nodes,  # included for context
                    "synchronised_slave_nodes": synced_nodes,  # included for context
                }
            )

        except requests.exceptions.RequestException as exc:
            print(f"Failed to fetch queue {name}: {exc}")
        except Exception as exc:  # pragma: no cover
            print(f"Unexpected error for queue {name}: {exc}")

    return result


def filter_long_queues(queue_info, threshold_ms=900_000):
    """Queues whose drain-time ≥ threshold."""
    return [
        {
            "name": q["name"],
            "messages": q["total_messages"],
            "time_to_complete_ms": q["time_to_complete_ms"],
        }
        for q in queue_info
        if q.get("time_to_complete_ms") is not None
           and q["time_to_complete_ms"] >= threshold_ms
    ]


def filter_unsynchronized_mirrors(queue_info):
    """Return queues with at least one unsynchronized mirror."""
    return [
        {
            "name": q["name"],
            "slave_nodes": q["slave_nodes"],
            "synchronised_slave_nodes": q["synchronised_slave_nodes"],
        }
        for q in queue_info
        if q.get("unsynchronized_mirrors")
    ]


def check_high_queues(input_list):
    """Convenience helper (unchanged)."""
    return len(input_list) > 1


def main():  # noqa: C901
    module = AnsibleModule(
        argument_spec={
            "uri": {"type": "str", "required": True},
            "username": {"type": "str", "required": True},
            "password": {"type": "str", "required": True, "no_log": True},
            "max_consumers": {"type": "int", "default": 1000},
            "max_queues": {"type": "int", "default": 100},
            "queue_ratio": {"type": "float", "default": 0.8},
            "max_lag": {"type": "int", "default": 15},  # seconds
        },
        supports_check_mode=True,
    )

    params = module.params
    uri, username, password = params["uri"], params["username"], params["password"]

    queue_names = get_queue_names(uri, username, password)
    queue_stats = get_queues_stats(uri, username, password, queue_names)

    long_queues = filter_long_queues(queue_stats)
    unsync = filter_unsynchronized_mirrors(queue_stats)

    results = {
        "rabbitmq": {
            "is_high_queues": check_high_queues(long_queues),
            "high_queues": long_queues,
            "is_unsynchronized_mirrors": bool(unsync),
            "unsynchronized_mirrors": unsync,
        }
    }

    module.exit_json(changed=False, **results)


if __name__ == "__main__":
    main()
