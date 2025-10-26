import asyncio
import logging
import multiprocessing
import multiprocessing as mp
import re
from concurrent.futures import ProcessPoolExecutor
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from datetime import datetime, timezone
from datetime import timedelta
from typing import Optional, Dict, List, Mapping, Any, Awaitable
from typing import Tuple

import aioboto3
import boto3
import yaml
from botocore.exceptions import ClientError
from fastapi import HTTPException, status, Request, Query

import database
import logs
from dependencies import router, read_current_user

cpu_count = multiprocessing.cpu_count()
_BW_RE = re.compile(r"(?P<value>\d+(?:\.\d+)?)\s*(?i:g(?:b(?:it|its|ps)?)?)")
INSTANCE_BW_CACHE: dict[str, float] = {}

_WORKERS = ThreadPoolExecutor(max_workers=cpu_count)
session = aioboto3.Session()
process_pool: ProcessPoolExecutor = ProcessPoolExecutor(max_workers=cpu_count, mp_context=mp.get_context("spawn"))

try:
    with open("config.yaml", "r", encoding="utf-8") as file:
        base_config = yaml.safe_load(file.read())
except FileNotFoundError:
    logs.logging.warning(f"Warning: config.yaml not found. 'system_prompt' will be empty.")
    raise
except Exception as e:
    logs.logging.error(f"An error occurred reading config.yaml: {e}")
    raise


def parse_es_shorthand(time_str: str) -> datetime:
    now = datetime.utcnow()
    if time_str == "now":
        return now

    match = re.match(r"now([-+])(\d+)([smhd])", time_str)
    if not match:
        raise ValueError(f"Unsupported time format: {time_str}")

    sign, value, unit = match.groups()
    value = int(value)

    delta = {
        's': timedelta(seconds=value),
        'm': timedelta(minutes=value),
        'h': timedelta(hours=value),
        'd': timedelta(days=value),
    }[unit]

    return now - delta if sign == "-" else now + delta


def parse_iso8601(dt_str):
    return datetime.fromisoformat(dt_str.replace("Z", "+00:00"))


def milliseconds_since_now(dt):
    last_dt = datetime.fromisoformat(dt)
    if last_dt.tzinfo is None:
        # ensure we’re in UTC (since you used datetime.now(timezone.utc).isoformat())
        last_dt = last_dt.replace(tzinfo=timezone.utc)

    now_dt = datetime.now(timezone.utc)

    return int((now_dt - last_dt).total_seconds() * 1_000)


def server_status_check(tasks) -> dict:
    def compare(val, logic, threshold):
        if isinstance(val, (int, float)):
            val_comp = val
        elif isinstance(val, (list, str)):
            val_comp = len(val)
        else:
            raise TypeError(f"Unsupported type for comparison: {type(val)}")

        if logic == "gte":
            return val_comp >= threshold
        if logic == "lte":
            return val_comp <= threshold
        if logic == "equals":
            return val == threshold or val_comp == threshold
        if logic == "not_equals":
            return val != threshold or val_comp != threshold
        raise ValueError(f"Unknown compare_logic: {logic!r}")

    fail_state = base_config["status_checks"]["fail_state"]
    final_result = {}

    for snapshot in tasks:
        # 1. Handle default/global metrics like LastUpdate
        for metric, conditions in fail_state.get("default", {}).items():
            found = False
            for service_dict in snapshot:
                if metric in service_dict:
                    val = service_dict[metric]
                    found = True
                    # break
            if not found:
                continue
            for condition in conditions:
                if compare(val, condition["compare_logic"], condition["value"]):
                    final_result.setdefault("default", {})[metric] = {
                        "description": condition.get("description", ""),
                        "result": True,
                        "detail": val,
                    }
                    # break  # first match only

        # 2. Service-specific metrics
        for service_dict in snapshot:
            for service, conf in fail_state.items():
                if service == "default" or service not in service_dict:
                    continue

                data = service_dict[service]

                # ---------- CloudWatch special case ----------
                if service == "cloudwatch" and isinstance(conf, dict):
                    # Each metric (e.g. "cpu") has a list of datapoints.
                    for metric, conditions in conf.items():
                        datapoints = data.get(metric, [])
                        if not datapoints:
                            continue
                        # Pick the newest datapoint by Timestamp and use its Average
                        latest_point = max(
                            datapoints, key=lambda d: d.get("Timestamp", "")
                        )
                        val = latest_point.get("Average")
                        if val is None:
                            continue

                        for condition in conditions:
                            if compare(val, condition["compare_logic"], condition["value"]):
                                final_result.setdefault(service, {})[metric] = {
                                    "description": condition.get(
                                        "description",
                                        f"{metric} {condition['compare_logic']} {condition['value']}",
                                    ),
                                    "result": True,
                                    "detail": val,
                                }
                                # break  # first match for this metric
                    continue  # done with CloudWatch, move to next service
                # ---------- End CloudWatch special case ----------

                # CASE A: List-based services (e.g., disk, ram)
                if isinstance(conf, list):
                    for condition in conf:
                        logic = condition["compare_logic"]
                        threshold = condition["value"]
                        description = condition.get("description", "")

                        if service == "disk":
                            partition = condition.get("partition")
                            for d in data:
                                if d.get("partition") == partition:
                                    val = d.get("percent")
                                    if compare(val, logic, threshold):
                                        final_result.setdefault(service, {})[
                                            partition
                                        ] = {
                                            "description": description,
                                            "result": True,
                                            "detail": val,
                                        }
                                        # break  # first match for this partition
                        elif service == "ram":
                            val = data.get("percentage") if isinstance(data, dict) else data
                            if val is not None and compare(val, logic, threshold):
                                final_result.setdefault(service, {})[
                                    "percentage"
                                ] = {
                                    "description": description,
                                    "result": True,
                                    "detail": val,
                                }
                                # break  # first match for ram

                # CASE B: Dict-based services (e.g., mongodb)
                elif isinstance(conf, dict):
                    for metric, conditions in conf.items():
                        for condition in conditions:
                            logic = condition["compare_logic"]
                            threshold = condition["value"]
                            description = condition.get(
                                "description", f"{metric} {logic} {threshold}"
                            )
                            val = data.get(metric)
                            if val is not None and compare(val, logic, threshold):
                                final_result.setdefault(service, {})[metric] = {
                                    "description": description,
                                    "result": True,
                                    "detail": val,
                                }
                                # break  # first match per metric
                                continue

    return final_result


async def lookup_bandwidth_gbps(instance_type: str, region: str) -> float:
    """
    Asynchronously return the advertised baseline network bandwidth for `instance_type`
    in gigabits per second (float), caching results in INSTANCE_BW_CACHE.
    """
    # -- hit cache first ---------------------------------------------------
    if instance_type in INSTANCE_BW_CACHE:
        return INSTANCE_BW_CACHE[instance_type]

    # -- ask EC2 asynchronously --------------------------------------------
    async with session.client("ec2", region_name=region) as ec2:
        resp = await ec2.describe_instance_types(InstanceTypes=[instance_type])

    perf_str = resp["InstanceTypes"][0]["NetworkInfo"]["NetworkPerformance"]

    # -- parse number ------------------------------------------------------
    m = _BW_RE.search(perf_str.replace("Gigabit", "Gbps"))  # normalize
    if not m:
        # fallback if we can’t parse it
        print(f"⚠️  Could not parse bandwidth from “{perf_str}”, defaulting to 0")
        gbps = 0.0
    else:
        gbps = float(m.group("value"))

    # -- remember & return -------------------------------------------------
    INSTANCE_BW_CACHE[instance_type] = gbps
    return gbps


async def es_bulk_index(all_actions: List[Dict[str, Any]]) -> None:
    from elasticsearch.helpers import async_bulk
    """
    Bulk-index into ES in 500-doc chunks using the async ES client.
    Each action: {'_index':'ec2_metrics','_source':{…}}.
    """
    if not all_actions:
        return

    es = database.get_es_client()

    chunk_size = 500
    for i in range(0, len(all_actions), chunk_size):
        chunk = all_actions[i: i + chunk_size]
        # use the async helper directly against the async client
        await async_bulk(
            client=es,
            actions=chunk,
            stats_only=True,
            max_retries=3,
            request_timeout=60,
        )


def build_msearch_body(
        labels: List[str],
        instance_id: str,
        start_iso: str,
        end_iso: str
) -> List[Dict[str, Any]]:
    """
    Construct the body for an ES msearch across multiple metric labels.
    """
    body: List[Dict[str, Any]] = []
    for label in labels:
        body.append({'index': 'ec2_metrics'})
        body.append({
            'size': 10000,
            'sort': [{'timestamp': 'asc'}],
            'query': {
                'bool': {
                    'must': [
                        {'term': {'instance_id': instance_id}},
                        {'term': {'metric': label}},
                        {'range': {'timestamp': {'gte': start_iso, 'lte': end_iso}}}
                    ]
                }
            }
        })
    return body


async def es_bulk_load(
        labels: List[str],
        instance_id: str,
        start_iso: str,
        end_iso: str
) -> Dict[str, List[Dict[str, Any]]]:
    """
    Perform one msearch to load all named metrics from ES.
    Returns mapping: label → list of docs.
    """
    es = database.get_es_client()

    body = build_msearch_body(labels, instance_id, start_iso, end_iso)
    resp = await es.msearch(body=body)
    out: Dict[str, List[Dict[str, Any]]] = {}
    for label, sub in zip(labels, resp.get('responses', [])):
        docs: List[Dict[str, Any]] = []
        for h in sub.get('hits', {}).get('hits', []):
            src = h['_source']
            doc: Dict[str, Any] = {
                'Timestamp': datetime.fromisoformat(src['timestamp']),
                'Value': src['value'],
                'Unit': src['unit'],
            }
            if 'volume_id' in src:
                doc['volume_id'] = src['volume_id']
                doc['partition'] = src['partition']
            docs.append(doc)
        out[label] = docs
    return out

    # ─────── Main function ───────────────────────────────────────────────


async def get_instance_metrics(
        instance_id: str,
        start_time_iso: str,
        end_time_iso: str,
        region: str,
        instance_type: str,
        active_fetch_cloudwatch: bool,
        period: int = 300,
        partition_map: Optional[Dict[str, str]] = None
) -> Mapping[str, List[Dict[str, Any]]]:
    """
    1) Load existing metrics for this instance + volumes from ES.
    2) If active_fetch_cloudwatch=True, fetch missing CW datapoints and bulk-index them.
    3) Return merged ES+CW results, plus derived metrics:
       - network_total, network_total_pct
       - <mount-point>_throughput, <mount-point>_operations, <mount-point>_idle_time_pct
    """
    # AWS clients
    cw_client = boto3.client("cloudwatch", region_name=region)
    ec2_client = boto3.client("ec2", region_name=region)

    def parse_iso(ts: str) -> datetime:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone(timezone.utc)

    async def fetch_metric(
            namespace: str,
            name: str,
            dims: List[Dict[str, Any]],
            unit: str,
            stat: str,
            fetch_start: datetime,
            fetch_end: datetime
    ) -> List[Dict[str, Any]]:
        resp = await asyncio.to_thread(
            cw_client.get_metric_statistics,
            Namespace=namespace,
            MetricName=name,
            Dimensions=dims,
            StartTime=fetch_start,
            EndTime=fetch_end,
            Period=period,
            Statistics=[stat],
            Unit=unit,
        )
        dps = resp.get("Datapoints", [])
        return sorted(
            [{"Timestamp": dp["Timestamp"], "Value": dp[stat], "Unit": unit}
             for dp in dps],
            key=lambda d: d["Timestamp"]
        )

    # parse time window
    start_time = parse_iso(start_time_iso)
    end_time = parse_iso(end_time_iso)

    # describe instance to discover volumes
    try:
        desc = await asyncio.to_thread(
            ec2_client.describe_instances,
            InstanceIds=[instance_id]
        )
    except ClientError as e:
        if e.response.get("Error", {}).get("Code") == "InvalidInstanceID.NotFound":
            logs.logging.warning(f"Instance {instance_id} not found; skipping.")
            return {}
        raise

    try:
        mappings = desc["Reservations"][0]["Instances"][0]["BlockDeviceMappings"]
    except IndexError as e:
        logging.warn(f"Index error on mappings {e}")
        mappings = []
        pass
    # instance‐level metrics definitions
    METRICS = {
        "cpu": ("AWS/EC2", "CPUUtilization", [{"Name": "InstanceId", "Value": instance_id}], "Percent", "Average"),
        "network_in": ("AWS/EC2", "NetworkIn", [{"Name": "InstanceId", "Value": instance_id}], "Bytes", "Average"),
        "network_out": ("AWS/EC2", "NetworkOut", [{"Name": "InstanceId", "Value": instance_id}], "Bytes", "Average"),
    }

    # build ES labels for instance + per-volume
    metric_labels = list(METRICS.keys())
    vol_tasks: List[Tuple[str, str, str, str, List[Dict[str, Any]]]] = []
    for mapping in mappings:
        dev = mapping["DeviceName"]
        vol = mapping["Ebs"]["VolumeId"]
        dims = [{"Name": "VolumeId", "Value": vol}]
        for cw_metric in (
                "VolumeReadBytes", "VolumeWriteBytes",
                "VolumeReadOps", "VolumeWriteOps",
                "VolumeIdleTime"
        ):
            label = f"{vol}__{cw_metric}"
            metric_labels.append(label)
            vol_tasks.append((dev, vol, cw_metric, label, dims))

    # load existing points from ES
    loaded = await es_bulk_load(metric_labels, instance_id, start_time_iso, end_time_iso)

    results: Dict[str, List[Dict[str, Any]]] = {}
    all_actions: List[Dict[str, Any]] = []

    # 1️⃣ instance‐level: merge ES + optional CW
    for label, (ns, name, dims, unit, stat) in METRICS.items():
        existing = loaded.get(label, [])
        results[label] = existing.copy()

        if active_fetch_cloudwatch:
            fetch_start = (max(d["Timestamp"] for d in existing) + timedelta(seconds=period)
                           if existing else start_time)
            if fetch_start < end_time:
                new_pts = await fetch_metric(ns, name, dims, unit, stat, fetch_start, end_time)
                for dp in new_pts:
                    results[label].append(dp)
                    all_actions.append({
                        "_index": "ec2_metrics",
                        "_source": {
                            "timestamp": dp["Timestamp"].isoformat(),
                            "value": dp["Value"],
                            "unit": dp["Unit"],
                            "instance_id": instance_id,
                            "metric": label,
                        }
                    })

    # 2️⃣ per-volume raw: collect into temporary structure by mount-point
    key_map = {
        "VolumeReadBytes": "read_bytes",
        "VolumeWriteBytes": "write_bytes",
        "VolumeReadOps": "read_ops",
        "VolumeWriteOps": "write_ops",
        "VolumeIdleTime": "idle_time",
    }
    vol_data: Dict[str, Dict[str, Any]] = {}
    for dev, vol, cw_metric, label, dims in vol_tasks:
        existing = loaded.get(label, [])
        combined = existing.copy()

        # determine filesystem mount-point
        if dev == "/dev/sda1":
            part = "/"
        elif partition_map and vol in partition_map:
            part = partition_map[vol]
        else:
            part = dev

        # fetch missing CW points
        if active_fetch_cloudwatch:
            fetch_start = (max(d["Timestamp"] for d in existing) + timedelta(seconds=period)
                           if existing else start_time)
            if fetch_start < end_time:
                unit = ("Seconds" if "IdleTime" in cw_metric
                        else "Count" if "Ops" in cw_metric
                else "Bytes")
                new_pts = await fetch_metric(
                    "AWS/EBS", cw_metric, dims, unit, "Sum", fetch_start, end_time
                )
                for dp in new_pts:
                    dp["volume_id"] = vol
                    dp["partition"] = part
                    combined.append(dp)
                    all_actions.append({
                        "_index": "ec2_metrics",
                        "_source": {
                            "timestamp": dp["Timestamp"].isoformat(),
                            "value": dp["Value"],
                            "unit": dp["Unit"],
                            "instance_id": instance_id,
                            "metric": label,
                            "volume_id": vol,
                            "partition": part,
                        }
                    })

        # stash raw combined lists
        entry = vol_data.setdefault(part, {
            "device": dev,
            "volume_id": vol,
            **{v: [] for v in key_map.values()}
        })
        entry[key_map[cw_metric]] = combined

    # 3️⃣ bulk-index any new CW points
    if active_fetch_cloudwatch and all_actions:
        await es_bulk_index(all_actions)

    # 4️⃣ derive network totals
    if results.get("network_in") and results.get("network_out"):
        in_map = {d["Timestamp"]: d for d in results["network_in"]}
        out_map = {d["Timestamp"]: d for d in results["network_out"]}
        common_ts = sorted(in_map.keys() & out_map.keys())
        total_raw, total_pct = [], []
        bw_bps = None
        if instance_type:
            bw_bps = (INSTANCE_BW_CACHE.get(instance_type)
                      or await lookup_bandwidth_gbps(instance_type, region)) * 1e9

        for ts in common_ts:
            s = in_map[ts]["Value"] + out_map[ts]["Value"]
            total_raw.append({"Timestamp": ts, "Value": s, "Unit": "Bytes"})
            if bw_bps:
                pct = round((s * 8) / bw_bps * 100, 3)
                total_pct.append({"Timestamp": ts, "Value": pct, "Unit": "Percent"})

        results["network_total"] = total_raw
        if total_pct:
            results["network_total_pct"] = total_pct

    # 5️⃣ derive per-mount metrics
    for part, data in vol_data.items():
        vol_id = data["volume_id"]
        rb = {d["Timestamp"]: d for d in data["read_bytes"]}
        wb = {d["Timestamp"]: d for d in data["write_bytes"]}
        ro = {d["Timestamp"]: d for d in data["read_ops"]}
        wo = {d["Timestamp"]: d for d in data["write_ops"]}
        it = {d["Timestamp"]: d for d in data["idle_time"]}

        results[f"{part}_throughput"] = [
            {
                "Timestamp": ts,
                "Value": (rb[ts]["Value"] + wb[ts]["Value"]) / period,
                "Unit": "Bytes",
                "volume_id": vol_id,
                "partition": part
            }
            for ts in sorted(rb.keys() & wb.keys())
        ]
        results[f"{part}_operations"] = [
            {
                "Timestamp": ts,
                "Value": (ro[ts]["Value"] + wo[ts]["Value"]) / period,
                "Unit": "Ops/s",
                "volume_id": vol_id,
                "partition": part
            }
            for ts in sorted(ro.keys() & wo.keys())
        ]
        results[f"{part}_idle_time_pct"] = [
            {
                "Timestamp": ts,
                "Value": round(it[ts]["Value"] / period * 100, 3),
                "Unit": "Percent",
                "volume_id": vol_id,
                "partition": part
            }
            for ts in sorted(it.keys())
        ]

    return results


async def cluster_status(
        start_date: Optional[datetime],
        end_date: Optional[datetime],
        active_fetch_cloudwatch: bool,
        instance_id: Optional[str] = None,
) -> Dict[str, Any]:
    """Collect cluster health information using the **asynchronous** Elasticsearch driver.

    All business logic is unchanged. We now dispatch host‑level work with
    ``asyncio.create_task`` instead of ``run_in_executor`` so the task list is
    typed as ``Awaitable[dict]`` rather than ``Future[Coroutine[…]]``. This
    resolves the MyPy error.
    """
    es = database.get_es_client()

    # 1️⃣ Determine the time window
    if not end_date:
        end_date = datetime.now(timezone.utc)
    if not start_date:
        start_date = end_date - timedelta(minutes=30)

    def to_utc_iso(dt: datetime) -> str:
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        else:
            dt = dt.astimezone(timezone.utc)
        return dt.isoformat(timespec="seconds")

    start_iso = to_utc_iso(start_date)
    end_iso = to_utc_iso(end_date)

    # 2️⃣ Build the ES query template
    time_filter = {"gte": start_iso, "lte": end_iso}
    must_clause: List[dict] = [{"range": {"timestamp": time_filter}}]
    if instance_id:
        must_clause.append({"match": {"InstanceId": instance_id}})

    base_query: Dict[str, Any] = {
        "size": 1000,
        "query": {"bool": {"must": must_clause}},
        "sort": [{"ip": "asc"}, {"timestamp": "desc"}],
    }

    final_response: Dict[str, dict] = {}
    page_count, search_after = 0, None
    host_buffer: List[dict] = []
    current_ip: Optional[str] = None

    # Tasks created with create_task → Awaitable[dict]
    tasks: List[Awaitable[dict]] = []

    # 3️⃣ Scroll through pages (max 100)
    while page_count < 100:
        query = deepcopy(base_query)
        if search_after:
            query["search_after"] = search_after

        # 🚀 ASYNC search call – no thread hop needed
        resp = await es.search(
            index="monitoring_data",
            body=query,
        )
        hits = resp["hits"]["hits"]
        if not hits:
            break

        for hit in hits:
            doc = hit["_source"]
            ip = doc.get("ip")

            # When the IP changes, hand off accumulated docs for processing
            if current_ip and ip != current_ip:
                tasks.append(
                    asyncio.create_task(
                        _process_host(
                            current_ip,
                            host_buffer.copy(),
                            start_iso,
                            end_iso,
                            active_fetch_cloudwatch,
                        )
                    )
                )
                host_buffer.clear()

            host_buffer.append(doc)
            current_ip = ip

        search_after = hits[-1]["sort"]
        page_count += 1

    # 4️⃣ Dispatch the last batch
    if host_buffer and current_ip:
        tasks.append(
            asyncio.create_task(
                _process_host(
                    current_ip,
                    host_buffer.copy(),
                    start_iso,
                    end_iso,
                    active_fetch_cloudwatch,
                )
            )
        )

    # 5️⃣ Gather results
    results = await asyncio.gather(*tasks, return_exceptions=False)

    for host_data in results:
        ip = host_data.get("ip")
        if not ip:
            continue
        if instance_id:
            return host_data
        final_response[ip] = host_data

    return final_response


# --------------------------------------------------------------------------- #
# Existing helper function (unchanged)
# --------------------------------------------------------------------------- #

async def _process_host(
        ip: str,
        docs: List[dict],
        start_iso: str,
        end_iso: str,
        active_fetch_cloudwatch: bool,
) -> Dict[str, Any]:
    """Merge ES docs, enrich with CloudWatch metrics, and run health checks."""

    meta = docs[0]  # first doc contains metadata fields
    aggregated: Dict[str, Any] = {"ip": ip}

    single_fields = {
        "name", "ip", "Tags", "Program",
        "InstanceType", "InstanceId", "Region",
        "Provider", "State", "LaunchTime",
    }
    for doc in docs:
        for field, val in doc.items():
            if field in single_fields:
                aggregated.setdefault(field, val)
            else:
                aggregated.setdefault(field, []).append(val)

    # Build volume → partition map
    partition_map: Dict[str, str] = {}
    if aggregated.get("tasks"):
        first_snapshot = aggregated["tasks"][0]
        for service_dict in first_snapshot:
            if "disk" in service_dict and isinstance(service_dict["disk"], list):
                for disk_entry in service_dict["disk"]:
                    vol = disk_entry.get("volume_id")
                    part = disk_entry.get("partition")
                    if vol and part:
                        partition_map[vol] = part
                break

    # CloudWatch metrics
    aggregated["cloudwatch"] = {}
    try:
        aggregated["cloudwatch"] = await get_instance_metrics(
            instance_id=meta["InstanceId"],
            start_time_iso=start_iso,
            end_time_iso=end_iso,
            region=meta["Region"],
            instance_type=meta["InstanceType"],
            partition_map=partition_map,
            active_fetch_cloudwatch=active_fetch_cloudwatch,
        )
    except Exception:
        logs.logging.warning(f"Error loading metrics for {meta['InstanceId']}", exc_info=True)
        aggregated["cloudwatch"] = {}

    # Health/staleness checks
    if aggregated.get("tasks"):
        aggregated["failing_states"] = []

        cloudwatch_result = server_status_check([[{"cloudwatch": aggregated["cloudwatch"]}]])

        if cloudwatch_result:
            aggregated["failing_states"].append(cloudwatch_result)

        aggregated["active_issues"] = []

        for idx, task in enumerate(aggregated["tasks"]):
            result = server_status_check([task])
            if result:
                aggregated["failing_states"].append({"timestamp": aggregated["timestamp"][idx], **result})

        last_ts = aggregated.get("timestamp", [""])[0]
        threshold_ms = base_config["status_checks"]["fail_state"]["default"]["LastUpdate"]["value"]
        if last_ts and milliseconds_since_now(last_ts) >= threshold_ms:
            aggregated["failing_states"].append({"LastUpdate": {
                "description": base_config["status_checks"]["fail_state"]["default"]["LastUpdate"]["description"],
                "result": True,
            }})

    return aggregated


def to_utc_iso(dt: datetime) -> str:
    if dt.tzinfo is None:  # naïve → tag as UTC
        dt = dt.replace(tzinfo=timezone.utc)
    else:  # aware → convert to UTC
        dt = dt.astimezone(timezone.utc)
    return dt.isoformat(timespec="seconds")  # e.g. 2025-05-18T16:32:59+00:00


@router.get("/cluster_status/")
async def cluster_status_api(
        request: Request,
        start: str = Query(default=None),
        end: str = Query(default=None),
        active_fetch_cloudwatch: bool = Query(default=False)
):
    user = await read_current_user(request.headers.get("Authorization"))
    if not user['is_mfa_login']:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)

    start_dt = parse_iso8601(start) if start else None
    end_dt = parse_iso8601(end) if end else None
    return await cluster_status(start_date=start_dt, end_date=end_dt, active_fetch_cloudwatch=active_fetch_cloudwatch)
