#!/usr/bin/env python3.9

from __future__ import (absolute_import, division, print_function)

__metaclass__ = type

DOCUMENTATION = r'''
---
module: ram_info
short_description: Get RAM info of a Linux server
description:
    - Get the total, used, and available RAM in MB, and calculate the percentage of used RAM.
options: {}
author:
    - Your Name
'''

EXAMPLES = r'''
- name: Get RAM info
  ram_info:
  register: ram_info
'''

RETURN = r'''
total:
    description: Total RAM in MB
    type: float
    returned: always
used:
    description: Used RAM in MB
    type: float
    returned: always
available:
    description: Available RAM in MB
    type: float
    returned: always
percentage:
    description: Percentage of used RAM
    type: float
    returned: always
'''

from ansible.module_utils.basic import AnsibleModule


def get_ram_info():
    with open('/proc/meminfo', 'r') as f:
        lines = f.readlines()

    mem = {}
    for line in lines:
        key, val = line.split()[:2]
        mem[key.rstrip(':')] = int(val) / 1024.0  # kB → MB

    total = mem.get('MemTotal')
    free = mem.get('MemFree')
    buffers = mem.get('Buffers')
    cached = mem.get('Cached')
    available = mem.get('MemAvailable')

    if total is None or free is None or buffers is None or cached is None:
        return None

    # Prefer the kernel-provided Available if present
    if available is not None:
        used = total - available
    else:
        # Fall back: exclude buffers+cache from “used”
        available = free + buffers + cached
        used = total - free - buffers - cached

    pct_used = (used / total) * 100.0

    return {"ram": {
        "total": round(total, 2),
        "used": round(used, 2),
        "available": round(available, 2),
        "percentage": round(pct_used, 2),
    }}


def main():
    module = AnsibleModule(argument_spec={}, supports_check_mode=True)

    ram_data = get_ram_info()
    if ram_data is None:
        module.fail_json(msg="Could not read memory information from /proc/meminfo")

    module.exit_json(changed=False, **ram_data)


if __name__ == '__main__':
    main()
