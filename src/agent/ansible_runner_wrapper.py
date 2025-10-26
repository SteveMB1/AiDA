import asyncio
import collections
import json
import logging
import multiprocessing
import os
import shutil
import signal
import tempfile
from concurrent.futures import ThreadPoolExecutor
from functools import partial
from typing import Optional

import ansible_runner

import database
from .aws_wrapper import update_yaml_tags

# --- Executor setup ---------------------------------------------------------

# Use threads instead of processes so we can safely spawn child processes
cpu_count = multiprocessing.cpu_count()
ansible_executor = ThreadPoolExecutor(max_workers=cpu_count)


def _shutdown_executor(signum, frame):
    logging.info(f"Signal {signum} received: shutting down Ansible executor")
    ansible_executor.shutdown(wait=True)


# Register SIGINT/SIGTERM handlers so we clean up on exit
for sig in (signal.SIGINT, signal.SIGTERM):
    signal.signal(sig, _shutdown_executor)


# --- Helper functions -------------------------------------------------------

async def stage_ansible_run_dir(run_dir: Optional[str] = None) -> str:
    if run_dir is None:
        run_dir = await asyncio.to_thread(tempfile.mkdtemp, prefix="ansible_run_")
    logging.debug(f"Using isolated run dir: {run_dir}")

    agent_ansible_dir = os.path.abspath('agent/ansible')
    subdirs_to_link = ['playbooks', 'plugins']

    # Symlink all files in agent/ansible
    for item in await asyncio.to_thread(os.listdir, agent_ansible_dir):
        src = os.path.join(agent_ansible_dir, item)
        dest = os.path.join(run_dir, item)
        if await asyncio.to_thread(os.path.isfile, src):
            await asyncio.to_thread(os.symlink, src, dest)

    # Recursively symlink selected subdirectories
    for subdir in subdirs_to_link:
        src_dir = os.path.join(agent_ansible_dir, subdir)
        dest_dir = os.path.join(run_dir, subdir)
        if await asyncio.to_thread(os.path.isdir, src_dir):
            for root, _, files in await asyncio.to_thread(os.walk, src_dir):
                rel = os.path.relpath(root, src_dir)
                dest_root = os.path.join(dest_dir, rel)
                await asyncio.to_thread(os.makedirs, dest_root, exist_ok=True)
                for fname in files:
                    await asyncio.to_thread(
                        os.symlink,
                        os.path.join(root, fname),
                        os.path.join(dest_root, fname),
                    )

    return run_dir


def _parse_events(events) -> dict:
    by_host = collections.defaultdict(list)
    for ev in events:
        if ev.get('event') == 'runner_on_ok':
            host = ev['event_data']['host']
            task = ev['event_data'].get('task', '')
            res = ev['event_data'].get('res', {})
            if task != 'IgnoreTask':
                by_host[host].append(res.get('stdout', res))
    # ensure JSON-serializable
    return json.loads(json.dumps(by_host))


def merge_tasks(stats: dict, data: dict) -> dict:
    cleaned_data = {}
    for host, tasks in data.items():
        cleaned = []
        for t in tasks:
            if isinstance(t, dict):
                t.pop("invocation", None)
                t.pop("_ansible_no_log", None)
                t.pop("changed", None)
            cleaned.append(t)
        cleaned_data[host] = cleaned

    hosts_in_stats = {
        h
        for stat_map in stats.values()
        if isinstance(stat_map, dict)
        for h in stat_map
    }
    all_hosts = set(cleaned_data) | hosts_in_stats

    result = {}
    for host in all_hosts:
        host_stats = {
            stat: cnt
            for stat, host_map in stats.items()
            if isinstance(host_map, dict)
            for h, cnt in host_map.items()
            if h == host and cnt
        }
        result[host] = {
            'tasks': cleaned_data.get(host, []),
            'stats': host_stats
        }

    return result


# --- Core Ansible runner logic ----------------------------------------------

async def _run_and_cleanup(run_dir: str, extra_vars: dict):
    """Run cleanup playbook in executor, then delete run_dir."""
    try:
        loop = asyncio.get_running_loop()
        cleanup_job = partial(
            ansible_runner.run,
            private_data_dir=run_dir,
            playbook="playbooks/remove_tmp_ansible.yaml",
            extravars={'stdout_callback': 'json', **extra_vars},
        )
        await loop.run_in_executor(ansible_executor, cleanup_job)
    except Exception as e:
        logging.error("Cleanup playbook failed: %s", e)
    finally:
        # remove the temp directory
        await asyncio.to_thread(shutil.rmtree, run_dir, ignore_errors=True)
        logging.info("Removed run_dir %r", run_dir)


async def _ansible_run_internal(
        playbook: str,
        extra_vars: dict,
        loop,
        run_dir: Optional[str] = None,
        target_ips: Optional[list] = None
) -> Optional[dict]:
    # 1️⃣ prepare isolated run dir
    if run_dir is None:
        run_dir = await stage_ansible_run_dir()

    # 2️⃣ update YAML tags
    await asyncio.to_thread(
        update_yaml_tags,
        env_value=extra_vars['Environment'],
        project_value=extra_vars['Project'],
        regions=[extra_vars['Region']],
        program=extra_vars['Program'],
        path=run_dir
    )

    # 3️⃣ build ansible-runner args
    run_args = {
        "private_data_dir": run_dir,
        "playbook": playbook,
        "extravars": {"stdout_callback": "json", **extra_vars},
    }
    if target_ips:
        run_args["limit"] = ",".join(target_ips)

    # 4️⃣ offload ansible_runner.run to thread pool
    result = await loop.run_in_executor(
        ansible_executor,
        lambda: ansible_runner.run(**run_args)
    )

    # 5️⃣ parse events off the main thread
    data = await asyncio.to_thread(_parse_events, result.events)

    # 6️⃣ cleanup old ES documents
    delete_query = {
        "query": {
            "bool": {
                "must": [
                    {"terms": {"Tags.Environment": [extra_vars["Environment"]]}},
                    {"terms": {"Tags.Project": [extra_vars["Project"]]}},
                    {"terms": {"Program": [extra_vars["Program"]]}},
                    {"exists": {"field": "ip"}}
                ],
                "must_not": [
                    {"terms": {"ip": list(data.keys())}}
                ]
            }
        }
    }
    await database.es_client.delete_by_query(
        index="monitoring_data",
        body=delete_query
    )

    # 7️⃣ schedule cleanup in background, don’t await
    asyncio.create_task(_run_and_cleanup(run_dir, extra_vars))

    # 8️⃣ merge stats/tasks off the main thread and return
    return await asyncio.to_thread(merge_tasks, result.stats, data)


async def ansible_run(
        playbook: str,
        extra_vars: dict,
        run_dir: Optional[str] = None,
        target_ips: Optional[list] = None
) -> Optional[dict]:
    loop = asyncio.get_running_loop()
    try:
        return await asyncio.wait_for(
            _ansible_run_internal(playbook, extra_vars, loop, run_dir, target_ips),
            timeout=600  # 10 minutes
        )
    except asyncio.TimeoutError:
        logging.error("Ansible run timed out after 10 minutes.")
        return None
    except Exception as e:
        logging.error(f"Ansible run failed: {e}")
        return None
