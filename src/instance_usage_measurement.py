#!/usr/bin/env python3
"""
EC2 instance right-sizer + remote RAM reporter.

Changes in this revision
------------------------
• Smarter _to_mib() heuristic – stops mis-classifying big MiB values as bytes.
• Reason line prints 1 decimal place so 243.0 MiB doesn't show up as 0.

Dependencies
------------
- boto3  (required)
- psutil (optional, controller-side RAM stats)
"""
from __future__ import annotations

import math
import os
import re
import statistics
from functools import lru_cache
from typing import Union, Dict, List, Tuple, Any

# --------------------------------------------------------------------------- #
#  Third-party imports                                                        #
# --------------------------------------------------------------------------- #
try:
    import psutil
except ImportError:  # pragma: no cover
    psutil = None  # type: ignore

import boto3

# --------------------------------------------------------------------------- #
#  Constants & helpers                                                        #
# --------------------------------------------------------------------------- #
BYTES_PER_MIB = 1024 * 1024


def _to_mib(val: Union[int, float, None]) -> float:
    """
    Convert an unknown RAM number to MiB.

    Heuristic (v2):
    • 0 or None ⟶ 0
    • If the value has a fractional part it’s almost certainly already MiB
      (bytes are always integers) → return unchanged.
    • Else if the integer value is less than 8 192 000 it’s very unlikely
      to be bytes (that would be < 8 GiB total RAM) → treat as MiB.
    • Otherwise treat as bytes and divide by 1 048 576.
    """
    if not val:
        return 0.0

    if isinstance(val, float) and not val.is_integer():
        return float(val)

    if val < 8_192_000:  # < 8 GiB if it were bytes
        return float(val)

    return float(val) / BYTES_PER_MIB


def get_current_ram_usage_mib() -> float:
    """RAM used on THIS controller, in MiB."""
    if psutil is not None:  # pragma: no cover
        return psutil.virtual_memory().used / BYTES_PER_MIB
    if os.name == "posix" and os.path.exists("/proc/meminfo"):  # pragma: no cover
        meminfo: Dict[str, int] = {}
        with open("/proc/meminfo", "r", encoding="utf-8") as fh:
            for line in fh:
                key, _, rest = line.partition(":")
                meminfo[key.strip()] = int(rest.split()[0])  # kB
        used_kib = meminfo["MemTotal"] - meminfo["MemAvailable"]
        return used_kib / 1024.0
    raise RuntimeError("Cannot determine local RAM usage – install psutil or run on Linux.")


# --------------------------------------------------------------------------- #
#  AWS helpers                                                                #
# --------------------------------------------------------------------------- #
ec2 = boto3.client("ec2", region_name="us-east-1")
type_specs: Dict[str, Dict[str, Any]] = {}


@lru_cache(maxsize=256)
def get_instance_specs(instance_type: str) -> Dict[str, Any]:
    if instance_type in type_specs:
        return type_specs[instance_type]
    resp = ec2.describe_instance_types(InstanceTypes=[instance_type])
    info = resp["InstanceTypes"][0]
    specs = {
        "vcpus": info["VCpuInfo"]["DefaultVCpus"],
        "memory_mib": info["MemoryInfo"]["SizeInMiB"],
        "architectures": info.get("ProcessorInfo", {}).get("SupportedArchitectures", []),
    }
    type_specs[instance_type] = specs
    return specs


def list_instance_types(family_prefix: str) -> List[str]:
    paginator = ec2.get_paginator("describe_instance_types")
    out: List[str] = []
    for page in paginator.paginate():
        for inst in page["InstanceTypes"]:
            it = inst["InstanceType"]
            if it.startswith(f"{family_prefix}."):
                out.append(it)
    return out


# --------------------------------------------------------------------------- #
#  Sizing helpers                                                             #
# --------------------------------------------------------------------------- #
def get_dynamic_itil_swap(memory_mib: int,
                          max_factor: float = 2.0,
                          min_factor: float = 1.0,
                          decay_scale_mib: int = 16 * 1024) -> int:
    interp = math.exp(-memory_mib / decay_scale_mib)
    factor = min_factor + (max_factor - min_factor) * interp
    return math.ceil(memory_mib * factor)


def _extract_ram_from_tasks(tasks: List[Any]) -> Tuple[float, float, float]:
    """
    Find the first dict that looks like {'ram': {...}} and return
    (total_mib, used_mib, pct).  Zeroes if nothing found.
    """
    for task in tasks:
        if not isinstance(task, (list, tuple)):
            continue
        for blob in task:
            if isinstance(blob, dict) and "ram" in blob:
                r = blob["ram"]
                total = _to_mib(r.get("total"))
                used = _to_mib(r.get("used"))
                pct = r.get("percentage") or (used / total * 100 if total else 0)
                return total, used, pct
    return 0.0, 0.0, 0.0


def _mean_cpu_pct(points):
    vals = [p["Value"] for p in points if p and p.get("Value") is not None]
    if not vals:
        return 0.0
    m = statistics.mean(vals)
    return m * 100 if m <= 1 else m


def _cmp_size(a: str, b: str) -> int:
    """Return -1 if a < b, 0 if equal, +1 if a > b (by vCPU, then RAM)."""
    sa, sb = get_instance_specs(a), get_instance_specs(b)
    if sa["vcpus"] != sb["vcpus"]:
        return (sa["vcpus"] > sb["vcpus"]) - (sa["vcpus"] < sb["vcpus"])
    return (sa["memory_mib"] > sb["memory_mib"]) - (sa["memory_mib"] < sb["memory_mib"])


# --------------------------------------

# --------------------------------------------------------------------------- #
#  Main decision engine                                                       #
# --------------------------------------------------------------------------- #
def recommend_instance(host: Dict[str, Any],
                       cpu_upper: float = 75.0,
                       cpu_lower: float = 25.0,
                       swap_upper: float = 75.0,
                       swap_lower: float = 25.0,
                       net_upper: float = 75.0,
                       net_lower: float = 25.0) -> Dict[str, Any]:
    current = host["InstanceType"]
    specs = get_instance_specs(current)
    total_ram_mib = specs["memory_mib"]

    # CPU %
    cpu_vals = [m["Value"] for m in host.get("cloudwatch", {}).get("cpu", [])]
    cpu_pct = _mean_cpu_pct(host.get("cloudwatch", {}).get("cpu", []))
    req_vcpus = max(1, math.ceil(specs["vcpus"] * cpu_pct / 100 * 2))

    # RAM
    mem_total_mib, mem_used_mib, mem_pct = _extract_ram_from_tasks(host.get("tasks", []))

    # SWAP
    used_swap_mib = configured_swap_mib = swap_pct = 0.0
    for t in host.get("tasks", []):
        if not isinstance(t, (list, tuple)) or len(t) < 2:
            continue
        for d in t[1].get("disk", []) or []:
            if d.get("partition") == "swap":
                used_swap_mib = _to_mib(d.get("used", 0))
                configured_swap_mib = _to_mib(d.get("total", 0))
                if configured_swap_mib:
                    swap_pct = used_swap_mib / configured_swap_mib * 100
                break
        if configured_swap_mib:
            break

    rec_swap_mib = get_dynamic_itil_swap(total_ram_mib)
    effective_swap_mib = min(rec_swap_mib, configured_swap_mib) if configured_swap_mib else rec_swap_mib

    # Network %
    net_vals = [m["Value"] for m in host.get("cloudwatch", {}).get("network_total_pct", [])]
    net_pct = statistics.mean(net_vals) if net_vals else 0.0

    # Candidate instance list
    family = re.match(r"^(.*?)\.", current).group(1)  # type: ignore
    arch_curr = set(specs["architectures"])
    cands = sorted(
        (it for it in list_instance_types(family) if arch_curr & set(get_instance_specs(it)["architectures"])),
        key=lambda it: (get_instance_specs(it)["vcpus"], get_instance_specs(it)["memory_mib"])
    )

    def pick_smallest(v_need: int, m_need: int) -> str:
        for it in cands:
            sp = get_instance_specs(it)
            if sp["vcpus"] >= v_need and sp["memory_mib"] >= m_need:
                return it
        return cands[-1]

    def pick_largest(v_cap: int, m_cap: int) -> str:
        for it in reversed(cands):
            sp = get_instance_specs(it)
            if sp["vcpus"] <= v_cap and sp["memory_mib"] <= m_cap:
                return it
        return cands[0]

    over = any((cpu_pct > cpu_upper, swap_pct > swap_upper, net_pct > net_upper))
    under = all((cpu_pct < cpu_lower, swap_pct < swap_lower, net_pct < net_lower))

    if configured_swap_mib:
        required_ram_up = math.ceil(used_swap_mib * 100 / swap_upper) - configured_swap_mib
        required_ram_up = max(required_ram_up, total_ram_mib)
    else:
        required_ram_up = total_ram_mib
    req_mem_up = required_ram_up + effective_swap_mib

    if configured_swap_mib:
        required_ram_down = math.ceil(used_swap_mib * 100 / swap_lower) - configured_swap_mib
    else:
        required_ram_down = total_ram_mib
    req_mem_min = math.ceil(mem_used_mib) + effective_swap_mib

    new_type = current
    reasons: List[str] = []

    target = current
    if over:
        target = pick_smallest(req_vcpus, req_mem_up)
    elif under:
        target = pick_smallest(req_vcpus, req_mem_min)

    # 2. Work out what that means --------------------------------------------
    cmp = _cmp_size(target, current)      #  -1 → smaller, 0 → same, +1 → bigger
    action = {1: "up", -1: "down", 0: "none"}[cmp]
    changed = cmp != 0

    reasons = []
    if action == "up":
        reasons.append(
            f"Scale **UP** – need ≥{req_vcpus} vCPU & ≥{req_mem_up} MiB RAM "
            f"(current {mem_total_mib:,.0f} MiB).")
    elif action == "down":
        reasons.append(
            f"Scale **DOWN** – utilisation low; smallest size that still fits "
            f"is {target} (≥{req_mem_min} MiB).")
    else:
        reasons.append("**No change** – current instance already fits the load.")

    reasons.append(
        f"Current RAM usage on host: {mem_used_mib:,.1f} / {mem_total_mib:,.1f} MiB "
        f"({mem_pct:.1f} %).")


    return {
        "NewInstanceType": target,
        "Reason": "\n".join(reasons),
        "changed": changed,
        "MemoryUsedMiB": mem_used_mib,
        "MemoryTotalMiB": mem_total_mib,
        "MemoryPct": mem_pct,
    }
