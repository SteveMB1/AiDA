from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import tempfile
import traceback
import uuid
from datetime import datetime, timezone
from typing import Tuple, Any, Dict, Optional

import yaml

from agent import ansible_runner_wrapper
from agent import aws_wrapper
from agent import database
from agent.ansible_runner_wrapper import stage_ansible_run_dir, ansible_run
from agent.ssh_config import generate_jump_host_ssh_config
from monitoring_status import cluster_status, parse_es_shorthand
from routes import get_answer

RESTART_DELAY_SEC = 5
os.environ['PATH'] += os.pathsep + ':/usr/local/bin/'

import sys

logging.basicConfig(
    level=logging.INFO,  # DEBUG if you want **everything**
    format="%(asctime)s  %(levelname)-8s  %(name)s: %(message)s",
    handlers=[
        logging.FileHandler("service.log", encoding="utf-8"),
        logging.StreamHandler(sys.stderr)  # keep stderr for kubectl logs etc.
    ],
    force=True  # clobber any previous config
)

headers = {
    "Content-Type": "application/json"
}

AIDA_ENDPOINT = "https://aida.radforge.io:8443"
MONITORING_ENDPOINT = "http://monitoring-1:9200"

try:
    with open("agent/config.yaml", "r", encoding="utf-8") as file:
        base_config = yaml.safe_load(file.read())
except FileNotFoundError:
    logging.warning(f"Warning: config.yaml not found. 'system_prompt' will be empty.")
    raise
except Exception as e:
    logging.error(f"An error occurred reading config.yaml: {e}")
    raise


def extract_container_name(k8s_string: str) -> Tuple[str, bool]:
    """
    Extracts and returns the container name from a string that
    follows the pattern 'k8s-<container_name>k8s-...', along with
    a boolean indicating whether it matched the pattern.
    """
    match = re.match(r'^k8s-(.*?)k8s-.*', k8s_string)
    if match:
        return match.group(1), True
    else:
        return k8s_string, False


def json_to_yaml_file(json_data, run_dir):
    """
    Convert a JSON-serializable object to a YAML file in the specified run directory.

    Args:
        json_data (dict or list): The data to serialize to YAML.
        run_dir (str): Base directory where the 'playbooks' folder will be created.

    Returns:
        str or None: Path to the created YAML file, or None if an error occurred.
    """
    try:
        # Ensure the 'playbooks' directory exists
        playbooks_dir = os.path.join(run_dir, "playbooks")
        os.makedirs(playbooks_dir, exist_ok=True)

        # Generate a unique filename with .yaml extension
        uuid_str = str(uuid.uuid4())
        file_path = os.path.join(playbooks_dir, f"{uuid_str}.yaml")

        # Write the data as YAML
        with open(file_path, "w") as f:
            yaml.safe_dump(json_data, f)

        return file_path
    except Exception as e:
        logging.error(f"[json_to_yaml_file] - {e}")
        return None


async def initial_diag(
        new_issue_question: str,
        environment: str,
        hostname: str,
        program: str,
        categories: str,
        project: str,
        ip: str,
        metrics: dict,
        region: str,
        config: dict = None,
):
    """
    Handles a single error "issue" – runs repeated steps asking the LLM
    for commands, executing them, and feeding the output back to the LLM
    until 'complete' is signaled. It won't give up if something fails
    during streaming; it keeps retrying (handled by stream_response()).
    """
    descriptions = []
    program, is_container = extract_container_name(program)

    # Determine program type and system prompt
    if is_container:
        system_prompt = get_system_prompt("agent/instructions_application.txt")
        program_type = "container"
    else:
        system_prompt = get_system_prompt("agent/instructions_general.txt")
        program_type = "Program"

    # Build initial prompt
    about_program_prompt = (
        f"For future reference IP address is {ip}, type is {program_type} name {program}. "
        f"Make sure you get every character correct. "
    )

    # Add categories to prompt if available
    if isinstance(categories, dict) and len(categories.get("categories", [])) > 0:
        categories_list = categories["categories"]
        prompt = (
                about_program_prompt
                + f"Here are the current categories: {categories_list}. Create new ones or choose a "
                  f"relevant set of categories when `complete` is true, generalize the category terms. "
                + f"Here's more information about the server: {metrics}. "
                + system_prompt
        )
    else:
        prompt = about_program_prompt + system_prompt

    # Initialize config if needed
    if config is None:
        config = {
            "question": str(new_issue_question),
            "internal_codebase_related": False,
            "external_codebase_related": False,
            "advanced_diagnostic_mode": True,
            "advanced_diagnostic_config": {
                "previous_questions": [],
                "previous_answers": [],
                "tracking_id": str(uuid.uuid4()),
                "environment": environment,
                "project": project,
                "hostname": hostname,
                "program": program,
                "ip": ip,
                "system_prompt": prompt,
            },
        }
    else:
        # If config is provided, explicitly set the question for this iteration
        config["question"] = str(new_issue_question)

    # Main loop
    iteration_count = 0
    iteration_error_count = 0
    while True:
        iteration_count += 1
        logging.debug(f"[initial_diag] Iteration #{iteration_count}. Question: {config['question']}")

        try:
            # Get answer from LLM
            response = []
            async for chunk in get_answer(
                    options=config,
                    question=config["question"],
                    user="Advanced AI Diagnostics",
            ):
                response.append(chunk)

            # Parse response
            first_round = json.loads("".join(response))

            # Check if response is valid
            if not first_round:
                logging.debug("[initial_diag] No valid response from LLM (unlikely). Breaking.")
                break

            # Check if model is complete
            if first_round.get("complete"):
                logging.debug(f"[initial_diag] Model completed: {first_round}")
                break

            # Extract description and command
            if first_round.get("description") is not None:
                descriptions.append(first_round["description"])
                logging.debug(f"[initial_diag] Hypothesis: {first_round['description']}")

            command = first_round.get("ansible_playbook")
            if not command:
                logging.debug(f"[initial_diag] No command provided by LLM, stopping. {first_round}")
                break

            run_dir = await asyncio.to_thread(tempfile.mkdtemp, prefix="ansible_run_")
            await stage_ansible_run_dir(run_dir)
            playbook_output_name = json_to_yaml_file([first_round.get("ansible_playbook")], run_dir=run_dir)
            print("Running Playbook:", playbook_output_name)
            cmd_result = await ansible_run(playbook=playbook_output_name,
                                           run_dir=run_dir,
                                           target_ips=[config["advanced_diagnostic_config"]['ip']],
                                           extra_vars={"Region": region,
                                                       "Program": config["advanced_diagnostic_config"]['program'],
                                                       "Environment": config["advanced_diagnostic_config"][
                                                           'environment'],
                                                       "Project": config["advanced_diagnostic_config"]['project']})

            # Update conversation log
            config["advanced_diagnostic_config"]["previous_questions"].append(str(command))
            config["advanced_diagnostic_config"]["previous_answers"].append(str(cmd_result))

            # Update question for next iteration
            new_issue_question = cmd_result
            config['question'] = new_issue_question
            iteration_error_count = 0

        except Exception as e:
            logging.error(f"[initial_diag] Error: {e}")
            if iteration_error_count >= 3:
                logging.error(f"[initial_diag] Ending after {iteration_error_count} attempts.")
                break
            iteration_count += 1
            pass

        # Avoid tight loop
        await asyncio.sleep(1)

    logging.debug("[initial_diag] Exiting loop.")


async def fetch_process():
    """
    Asynchronously fetches problems, spawns async tasks, waits for them,
    and captures their results. Continues indefinitely.
    """
    while True:
        try:
            # Fetch data concurrently
            results, categories_data = await asyncio.gather(
                cluster_status(start_date=parse_es_shorthand("now-30m"), end_date=parse_es_shorthand("now"),
                               active_fetch_cloudwatch=True),
                database.diagnostics_get_all_unique_categories()
            )

            # Extract troubled hosts
            troubled_hosts = [
                {
                    "hostname": host['name'],
                    "CurrentInstanceType": host['InstanceType'],
                    "Program": host['Tags']['Program'],
                    "Project": host['Tags']['Project'],
                    "ip": host['ip'],
                    "Region": host['Region'],
                    "Environment": host['Tags']['Environment'],
                    "failing_states": host['failing_states']
                }
                for host in results.values() if host['failing_states']
            ]

            if not troubled_hosts:
                await asyncio.sleep(5)
                continue

            # Prepare diagnostics tasks
            iteration_tasks = [
                asyncio.create_task(
                    initial_diag(
                        new_issue_question=host['failing_states'],
                        metrics=host,
                        environment=host['Environment'],
                        ip=host['ip'],
                        hostname=host['hostname'],
                        program=host['Program'],
                        project=host['Project'],
                        region=host['Region'],
                        categories=categories_data
                    )
                )
                for host in troubled_hosts
                if get_ai_diagnostics_enabled(project=host['Project'], environment=host['Environment'])
            ]

            # Run diagnostics concurrently
            results = await asyncio.gather(*iteration_tasks, return_exceptions=True)
            for i, result in enumerate(results):
                if isinstance(result, Exception):
                    logging.error(f"[fetch_process] Task #{i} raised an exception: {result}")
                else:
                    logging.info(f"[fetch_process] Task #{i} finished successfully.")

            await asyncio.sleep(base_config['status_checks']['refresh_rates']['passing_services_sec'])

        except Exception as e:
            logging.error(f"[fetch_process] Exception in main loop: {e}")
            await asyncio.sleep(5)


def get_ai_diagnostics_enabled(project, environment):
    """
    Returns the ai_diagnostics_enabled status based on the project and environment.

    Args:
    - project (str): The project name.
    - environment (str): The environment name.

    Returns:
    - bool: The ai_diagnostics_enabled status.
    """
    for env in base_config['status_checks']['environments']:
        if env['project'] == project and env['environment'] == environment:
            return env.get('ai_diagnostics_enabled', False)
    return None


def get_system_prompt(file_name):
    try:
        with open(file_name, "r", encoding="utf-8") as file:
            return file.read()
    except FileNotFoundError:
        logging.warning(f"Warning: {file_name} not found. 'system_prompt' will be empty.")
        return ""
    except Exception as e:
        logging.error(f"An error occurred reading {file_name}: {e}")
        return ""


async def create_ssh_config(region: str, filters: dict):
    bastion = await aws_wrapper.get_aws_instances(region=region, filters={"Program": "Bastion", **filters})
    generate_jump_host_ssh_config(
        cidr=f"{bastion['Bastion'][0]['PrivateIpAddress']}/22",
        jump_host=bastion['Bastion'][0]['PublicIpAddress'],
        user="ai-diagnostics",
        output_path=f"~/.ssh/config.d/{filters['Project']}-{filters['Environment']}.conf"
    )


async def handle_program(program, details, environment, filters):
    host_tag = details.get('host_tag')
    if host_tag:
        try:
            ansible_run_result = await ansible_runner_wrapper.ansible_run(
                extra_vars={
                    "Program": program,
                    "Environment": environment['environment'],
                    "Project": environment['project'],
                    "Region": environment['region']
                },
                playbook=" ".join(base_config['status_checks']['playbooks'])
            )

            return await add_hostname_to_records_and_insert_to_db(
                region=environment['region'],
                data=ansible_run_result,
                filters=filters,
                program=program
            )
        except Exception as e:
            logging.error(f"[handle_program:{program}] Error running Ansible: {e}")
    else:
        logging.info(f"Program '{program}' skipped: no host_tag")
        return None


async def handle_environment(environment):
    filters = {
        "Project": environment['project'],
        "Environment": environment['environment']
    }

    await create_ssh_config(region=environment['region'], filters=filters)

    if environment.get("programs"):
        tasks = [
            handle_program(program, details, environment, filters)
            for program, details in environment['programs'].items()
        ]
        await asyncio.gather(*tasks)


async def add_hostname_to_records_and_insert_to_db(region: str,
                                                   data: dict,
                                                   filters: dict,
                                                   program: str
                                                   ) -> list[dict[str, str]]:
    try:
        result = []
        instances = await aws_wrapper.get_aws_instances(region=region, filters=filters)

        for ip_addr, instance_details in data.items():
            for inst in instances.get(program, []):
                if inst['PrivateIpAddress'] == ip_addr:
                    result.append({
                        "name": inst['Tags']['Name'],
                        "ip": inst['PrivateIpAddress'],
                        "InstanceType": inst['InstanceType'],
                        "InstanceId": inst['InstanceId'],
                        "LaunchTime": inst['LaunchTime'],
                        "Region": inst['Region'],
                        "State": inst['State'],
                        "Provider": inst['Provider'],
                        "Program": program,
                        "Tags": inst['Tags'],
                        "timestamp": datetime.now(timezone.utc).isoformat(),
                        **instance_details
                    })

        # Insert all documents concurrently on threadpool
        tasks = [asyncio.create_task(database.insert_doc(record)) for record in result]
        await asyncio.gather(*tasks)

        return result

    except Exception as e:
        logging.error(f"[add_hostname…] Error: {e}")
        return []


async def fetch_runner(initial_backoff: float = 5.0) -> None:
    delay = initial_backoff
    while True:
        try:
            await fetch_process()
            delay = initial_backoff  # reset after success
        except Exception:
            logging.exception("fetch_process crashed – retrying in %.1f s", delay)
            await asyncio.sleep(delay)
            delay = min(delay * 2, 60)  # exponential back-off


# ───────────── 4.  LOOP-LEVEL EXCEPTION HANDLER ──────────────────────
def loop_exception_handler(loop: asyncio.AbstractEventLoop,
                           context: Dict[str, Any]) -> None:
    """
    Catch exceptions that escape our own try/except blocks,
    e.g. failed callbacks or orphaned Futures.
    """
    message = context.get("message", "Unhandled event-loop exception")
    exc: Optional[BaseException] = context.get("exception")
    if exc is not None:
        logging.exception("%s", message, exc_info=exc)
    else:
        logging.error("%s: %s", message, context)


# ───────────── 5.  MAIN & BOOTSTRAP ──────────────────────────────────

async def env_loop():
    refresh_rate = base_config['status_checks']['refresh_rates']['passing_services_sec']
    environments = base_config['status_checks']['environments'] or []

    while True:
        tasks = [handle_environment(env) for env in environments]
        try:
            # run all your environment-handlers in parallel
            await asyncio.gather(*tasks)
        except Exception as e:
            logging.error(f"[env_loop] An error occurred: {e}")
            traceback.print_exc()
            # back-off before retrying
            await asyncio.sleep(10)
        else:
            # pause until the next cycle
            await asyncio.sleep(refresh_rate)
