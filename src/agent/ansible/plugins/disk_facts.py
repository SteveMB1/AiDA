#!/usr/bin/env python3.9
import os
import subprocess
from typing import Optional

from ansible.module_utils.basic import AnsibleModule


def get_ebs_volume_id_from_sysfs(device_path: str) -> Optional[str]:
    """
    Read the EBS volume ID for a block device from sysfs.

    AWS writes the ID (without the dash) into:
      /sys/class/block/<dev‑name>/device/serial

    This returns a string like "vol-xxxx", or None if
    the file is missing or unreadable.
    """
    # resolve e.g. '/dev/nvme1n1' → '/dev/nvme1n1'
    try:
        real = os.path.realpath(device_path)
    except Exception:
        return None

    name = os.path.basename(real)
    serial_path = f"/sys/class/block/{name}/device/serial"

    try:
        with open(serial_path, "r") as f:
            raw = f.read().strip().lower()
    except (OSError, IOError):
        # file doesn't exist or no permissions
        return None

    if raw.startswith("vol-"):
        return raw
    elif raw.startswith("vol"):
        # drop the leading "vol" then re‑prefix with "vol-"
        return "vol-" + raw[3:]
    else:
        # unexpected format, but still prefix
        return "vol-" + raw


def _build_stat_entry(device, mount, size_kb, used_kb, avail_kb):
    size = int(size_kb)
    used = int(used_kb)
    avail = int(avail_kb)
    pct = round(used / size * 100, 2) if size else 0
    return {
        'partition': mount,
        'device': device,
        'total': size // 1024,
        'used': used // 1024,
        'available': avail // 1024,
        'percent': pct,
        'volume_id': get_ebs_volume_id_from_sysfs(device),
    }


def _build_swap_entry(device, size_kb, used_kb):
    size = int(size_kb)
    used = int(used_kb)
    avail = size - used
    pct = round(used / size * 100, 2) if size else 0
    return {
        'partition': 'swap',
        'device': device,
        'total': size // 1024,
        'used': used // 1024,
        'available': avail // 1024,
        'percent': pct,
    }


def collect_fs_stats(targets):
    cmd = ['df', '--output=source,target,size,used,avail', '--block-size=1K']
    try:
        lines = subprocess.check_output(cmd, text=True).splitlines()[1:]
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(f"'df' command failed: {exc}") from exc

    facts = []
    for line in lines:
        cols = line.split()
        if len(cols) < 5:
            continue
        device, mount, size_kb, used_kb, avail_kb = cols
        if device in targets or mount in targets:
            facts.append(_build_stat_entry(device, mount, size_kb, used_kb, avail_kb))
    return facts


def collect_swap_stats():
    try:
        with open('/proc/swaps', 'r') as f:
            lines = f.read().splitlines()[1:]
    except (OSError, IOError):
        return []

    facts = []
    for line in lines:
        cols = line.split()
        if len(cols) < 5:
            continue
        device, _, size_kb, used_kb, _ = cols
        facts.append(_build_swap_entry(device, size_kb, used_kb))
    return facts


def collect_all_stats(targets):
    stats = collect_fs_stats(targets)
    if any(t.lower() == 'swap' for t in targets):
        stats.extend(collect_swap_stats())
    return stats


def main():
    module = AnsibleModule(
        argument_spec=dict(
            partitions=dict(type='list', elements='str', required=True)
        ),
        supports_check_mode=True
    )

    targets = module.params['partitions']

    try:
        info = collect_all_stats(targets)
        module.exit_json(changed=False, disk=info)
    except Exception as exc:
        module.fail_json(msg=str(exc))


if __name__ == '__main__':
    main()
