#!/usr/bin/env python3.9

import argparse
import json
import sys

import redis


def main():
    parser = argparse.ArgumentParser(description='Standalone Redis health check script.')
    parser.add_argument('--host', default='localhost', help='Redis host (default: localhost)')
    parser.add_argument('--port', type=int, default=6379, help='Redis port (default: 6379)')
    parser.add_argument('--db', type=int, default=0, help='Redis database number (default: 0)')
    parser.add_argument('--password', default=None, help='Redis password (optional)')
    parser.add_argument('--test-key', default='ansible_redis_test', help='Key used for CRUD test')
    parser.add_argument('--test-value', default='ok', help='Value used in test key')
    args = parser.parse_args()

    result = {
        'changed': False,
        'failed': False,
        'redis': {
            'crud_check': '',
            'used_memory': None,
            'raw_memory_bytes': None
        },
    }

    try:
        # Connect
        r = redis.Redis(host=args.host, port=args.port, db=args.db, password=args.password)

        # SET
        if not r.set(args.test_key, args.test_value):
            result['failed'] = True
            result['redis_check']['crud_check'] = "SET failed"
            print(json.dumps(result, indent=2))
            sys.exit(1)

        # GET
        get_value = r.get(args.test_key)
        if get_value is None:
            result['failed'] = True
            result['redis_check']['crud_check'] = "GET failed: value is None"
            print(json.dumps(result, indent=2))
            sys.exit(1)

        if get_value.decode() != args.test_value:
            result['failed'] = True
            result['redis_check']['crud_check'] = (
                f"GET failed: expected '{args.test_value}', got '{get_value.decode()}'"
            )
            print(json.dumps(result, indent=2))
            sys.exit(1)

        # DEL
        if r.delete(args.test_key) != 1:
            result['failed'] = True
            result['redis_check']['crud_check'] = "DEL failed: key not deleted"
            print(json.dumps(result, indent=2))
            sys.exit(1)

        # INFO memory
        mem_info = r.info('memory')
        result['redis_check']['crud_check'] = "success"
        result['redis_check']['used_memory'] = mem_info.get('used_memory_human', 'unknown')
        result['redis_check']['raw_memory_bytes'] = mem_info.get('used_memory', 0)

    except Exception as e:
        result['failed'] = True
        result['msg'] = f"Redis check failed: {str(e)}"
        print(json.dumps(result, indent=2))
        sys.exit(1)

    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
