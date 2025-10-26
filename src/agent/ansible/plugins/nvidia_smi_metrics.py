#!/usr/bin/env python3

import subprocess

from ansible.module_utils.basic import AnsibleModule


def get_nvidia_smi_output():
    cmd = "nvidia-smi --query-gpu=index,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits"
    try:
        result = subprocess.check_output(cmd, shell=True, stderr=subprocess.DEVNULL)
        return result.decode('utf-8').strip()
    except subprocess.CalledProcessError:
        return None


def parse_nvidia_smi(output):
    metrics = []
    for line in output.strip().splitlines():
        fields = line.split(',')
        if len(fields) >= 5:
            try:
                utilization = int(fields[1].strip())
                mem_used = int(fields[2].strip())
                mem_total = int(fields[3].strip())
                temp = int(fields[4].strip())

                mem_percent = (mem_used / mem_total) * 100 if mem_total else 0
                temp_percent = min((temp / 100.0) * 100, 100)

                metrics.append({
                    "utilization": utilization,
                    "memory_percent": mem_percent,
                    "temperature_percent": temp_percent
                })
            except Exception:
                continue
    return metrics


def aggregate_metrics(metrics):
    total_gpus = len(metrics)
    avg_util = sum(g["utilization"] for g in metrics) / total_gpus
    avg_mem = sum(g["memory_percent"] for g in metrics) / total_gpus
    avg_temp = sum(g["temperature_percent"] for g in metrics) / total_gpus
    return {"nvidia": {
        "gpu_count": total_gpus,
        "average_utilization": round(avg_util, 1),
        "average_memory_used": round(avg_mem, 1),
        "average_temperature": round(avg_temp, 1)
    }}


def main():
    module = AnsibleModule(
        argument_spec={},
        supports_check_mode=True,
    )

    smi_output = get_nvidia_smi_output()
    if not smi_output:
        module.fail_json(msg="nvidia-smi command failed or is not available on the system")

    metrics = parse_nvidia_smi(smi_output)
    if not metrics:
        module.fail_json(msg="No valid GPU metrics could be parsed")

    aggregated = aggregate_metrics(metrics)
    module.exit_json(changed=False, **aggregated)


if __name__ == "__main__":
    main()
