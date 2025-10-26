#!/usr/bin/env python3.9

from __future__ import absolute_import, division, print_function

__metaclass__ = type

import datetime
import time

from ansible.module_utils.basic import AnsibleModule


def main():
    module = AnsibleModule(
        argument_spec=dict(
            max_allowed_drift=dict(type='float', required=False, default=5.0)
        ),
        supports_check_mode=True
    )

    # Get remote host time in UTC
    remote_time = datetime.datetime.utcnow()
    remote_timestamp = remote_time.timestamp()

    # Get controller time via module start time
    controller_time = datetime.datetime.utcnow()
    controller_timestamp = time.time()  # Unix timestamp on controller at time of module execution

    drift = controller_timestamp - remote_timestamp

    result = {"time_drift": {
        'controller_time': datetime.datetime.utcfromtimestamp(controller_timestamp).isoformat() + 'Z',
        'remote_time': remote_time.isoformat() + 'Z',
        'time_drift_seconds': round(controller_timestamp - remote_timestamp, 2),
        'changed': False,
    }}

    module.exit_json(**result)


if __name__ == '__main__':
    main()
