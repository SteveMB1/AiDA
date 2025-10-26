#!/usr/bin/env python3.9

"""
Extended MongoDB health-check Ansible module (flat keys).

Adds flat initial sync metrics:
- initial_sync_active: bool (this node in STARTUP2 / initial sync)
- initial_sync_any: bool (any member is in initial sync)
- initial_sync_progress_pct: float or None (0..100), if available

Other existing metrics preserved.
"""

import logging
from typing import Optional, Dict, Any

from ansible.module_utils.basic import AnsibleModule
from pymongo import MongoClient
from pymongo.errors import PyMongoError, ServerSelectionTimeoutError, OperationFailure

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


def _member_optime_seconds(member: dict) -> Optional[int]:
    """Extract seconds-since-epoch from a replSet member's optime."""
    opt = member.get("optime") or {}
    ts = opt.get("ts")
    try:
        if hasattr(ts, "time"):
            return int(ts.time)
    except Exception:
        pass
    od = member.get("optimeDate")
    try:
        if hasattr(od, "timestamp"):
            return int(od.timestamp())
    except Exception:
        pass
    return None


def _get_initial_sync_status(client: MongoClient, rs_doc: Optional[dict]) -> Optional[Dict[str, Any]]:
    """
    Try to fetch initial sync status as surfaced by replSetGetStatus during STARTUP2.
    Returns a dict with numeric fields (not nested under mongodb) or None if not present.
    """
    iss = None
    if isinstance(rs_doc, dict):
        iss = rs_doc.get("initialSyncStatus")

    if iss is None:
        # Some builds/versions require an explicit flag; if unsupported, it just fails.
        try:
            rs2 = client.admin.command("replSetGetStatus", initialSync=True)
            iss = rs2.get("initialSyncStatus")
        except PyMongoError:
            pass

    if not iss:
        return None

    try:
        copied = float(iss.get("approxTotalBytesCopied", 0))
        total = float(iss.get("approxTotalDataSize", 0))
    except Exception:
        return None

    if total <= 0:
        return {"progress_pct": None}

    return {"progress_pct": round((100.0 * copied / total), 2)}


def gather_mongodb_stats(host: str,
                         port: int,
                         max_connections: int,
                         queue_ratio: float,
                         max_lag_sec: int) -> dict:
    client = MongoClient(host=host, port=port, serverSelectionTimeoutMS=2000, directConnection=True)
    try:
        # 1) connectivity
        client.admin.command("ping")
        connected = True

        # 2) serverStatus (connections + queue)
        server_status = client.admin.command("serverStatus")
        conns = server_status.get("connections", {}) or {}
        connections_ok = conns.get("current", 0) <= max_connections * queue_ratio

        # 3) role + repl set status
        rs = None
        try:
            rs = client.admin.command("replSetGetStatus")
            state = rs.get("myState")
            role = {
                1: "primary",
                2: "secondary",
                5: "startup2",  # initial sync
                7: "arbiter",
            }.get(state, "other")
        except OperationFailure:
            hello = client.admin.command("hello")
            role = "router" if hello.get("msg") == "isdbgrid" else "other"

        # 3a) initial sync flags (flat)
        iss = _get_initial_sync_status(client, rs)
        initial_sync_active = (rs is not None and rs.get("myState") == 5) or (iss is not None)
        initial_sync_any = False
        if rs and rs.get("members"):
            for m in rs["members"]:
                st = m.get("state")
                if st == 5:
                    initial_sync_any = True
                    break

        initial_sync_progress_pct = iss["progress_pct"] if iss else None

        # 4) replication lag (two-pass)
        primary_optime = None
        max_lag_ms = 0
        if role in ("primary", "secondary", "arbiter") and rs and rs.get("members"):
            for m in rs["members"]:
                if m.get("stateStr") == "PRIMARY":
                    primary_optime = _member_optime_seconds(m)
                    break
            if primary_optime is not None:
                for m in rs["members"]:
                    if m.get("stateStr") == "SECONDARY":
                        tt = _member_optime_seconds(m)
                        if tt is None:
                            continue
                        lag = max(0, primary_optime - tt) * 1000
                        max_lag_ms = max(max_lag_ms, lag)
        lag_flag = max_lag_ms > max_lag_sec * 1000

        # 5) long-running ops (> 15 min). If not permitted, treat as OK but log.
        max_duration = 15 * 60
        try:
            current_ops = client.admin.command("currentOp", {"secs_running": {"$gte": max_duration}})
            long_running_ok = len(current_ops.get("inprog", [])) == 0
        except PyMongoError as e:
            logger.warning("currentOp failed (permissions?): %s", e)
            long_running_ok = True  # don't hard-fail the whole module

        # 6) queue size health (flat bool)
        queue = server_status.get("globalLock", {}).get("currentQueue", {}) or {}
        if queue:
            queue_size_total = int(queue.get("total", 0))
            queue_size_readers = int(queue.get("readers", 0))
            queue_size_writers = int(queue.get("writers", 0))
            # NOTE: Existing semantics compare observed to observed*ratio; usually too strict.
            thresholds_total = queue_size_total * queue_ratio
            thresholds_readers = queue_size_readers * queue_ratio
            thresholds_writers = queue_size_writers * queue_ratio
            queue_ok = all([
                queue_size_total <= thresholds_total,
                queue_size_readers <= thresholds_readers,
                queue_size_writers <= thresholds_writers,
                ])
        else:
            queue_ok = False  # unknown -> conservative

        # 7) replica set member connectivity probes
        replica_set_status = []
        if rs and rs.get("members"):
            for member in rs.get("members", []):
                name = member.get("name")
                if not name or ":" not in name:
                    continue
                member_host, member_port_str = name.split(":", 1)
                try:
                    member_port = int(member_port_str)
                except Exception:
                    member_port = 27017
                member_client = None
                try:
                    member_client = MongoClient(
                        host=member_host,
                        port=member_port,
                        serverSelectionTimeoutMS=2000,
                        directConnection=True
                    )
                    member_client.admin.command("ping")
                except Exception as e:
                    replica_set_status.append({
                        "host": name,
                        "error": str(e),
                        "stateStr": member.get("stateStr"),
                        "health": member.get("health", 0),
                    })
                finally:
                    if member_client:
                        member_client.close()

        # Final result — FLAT keys only under "mongodb"
        result = {
            "mongodb": {
                "role": role,
                "connection": connected,
                "connections": connections_ok,
                "long_running_operations": long_running_ok,
                "replication_lag_ms": max_lag_ms,
                "replication_lag": lag_flag,
                "replica_set_status": replica_set_status,  # list preserved (your policy uses it)
                "queue": queue_ok,

                # Flat sync metrics:
                "initial_sync_active": bool(initial_sync_active),
                "initial_sync_any": bool(initial_sync_any),
                "initial_sync_progress_pct": initial_sync_progress_pct,  # float or None
            }
        }

        return result

    except ServerSelectionTimeoutError:
        logger.error("Cannot connect to %s", host)
        return {"mongodb": {"connection": False, "replica_set_status": []}}
    except PyMongoError as e:
        logger.error("MongoDB error: %s", e)
        return {"mongodb": {"connection": False, "replica_set_status": []}}
    finally:
        client.close()


def main():
    module = AnsibleModule(
        argument_spec={
            "host": {"type": "str", "required": True},
            "port": {"type": "int", "required": True},
            "max_connections": {"type": "int", "default": 65000},
            "queue_ratio": {"type": "float", "default": 0.8},
            "max_lag": {"type": "int", "default": 15},
        },
        supports_check_mode=True,
    )

    host = module.params["host"]
    port = module.params["port"]
    max_conn = module.params["max_connections"]
    q_ratio = module.params["queue_ratio"]
    max_lag = module.params["max_lag"]

    stats = gather_mongodb_stats(host, port, max_conn, q_ratio, max_lag)
    module.exit_json(changed=False, **stats)


if __name__ == "__main__":
    main()
