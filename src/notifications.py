import asyncio
import datetime
import json
import re
import sys
from datetime import datetime, timezone

import aiohttp
import yaml
from fastapi import HTTPException, status
from fastapi import Request

import database
import logs
from authentication import get_user_full_name
from dependencies import router, read_current_user
from monitoring_status import cluster_status, parse_es_shorthand
from routes import generate_core

API_URL = "https://api.pagerduty.com/incidents"

try:
    with open("config.yaml", "r", encoding="utf-8") as file:
        base_config = yaml.safe_load(file.read())
except FileNotFoundError:
    logs.logging.warning(f"Warning: config.yaml not found. 'system_prompt' will be empty.")
    raise
except Exception as e:
    logs.logging.error(f"An error occurred reading config.yaml: {e}")
    raise


async def periodic_alert():
    """
    Calls pagerduty_alert(incident, config) every `interval_seconds`.
    """
    while True:
        json_response = {}
        troubled_hosts = []
        try:
            results = await cluster_status(parse_es_shorthand("now-30m"), parse_es_shorthand("now"),
                                           active_fetch_cloudwatch=False)
            for host in results.values():
                if host['failing_states']:
                    troubled_hosts.append({"name": host['name'], "Program": host['Program'],
                                           "failing_states": host['failing_states']})
            if len(troubled_hosts) > 0:
                chat_history = [{
                    "role": "system",
                    "content": (
                        'Describe the issues for a push notification, include shortened hostnames, include Program and environment.'
                        ' Be specific about the problems.'
                        ' Convert times to the easiest readable way.'
                        ' Make sure to include relevant information from the last message if not acknowledged.'
                        ' Responses should be only in complete and valid JSON on a single line: '
                        ' { "title": "Concise title based on the issue", "body": "summary of issues", "urgency": "Pick on of the following: high or low"}')

                }, {
                    "role": "user",
                    "content": str(troubled_hosts),
                }]

                response = []

                # Try to generate and accumulate the response
                async for chunk in generate_core(chat_history):
                    response.append(chunk)

                try:
                    json_response = json.loads("".join(response))
                except json.JSONDecodeError:
                    print("".join(response))
                    json_response = json.loads(re.search(r'```json\s*(.*?)\s*```', "".join(response), re.S).group(1))

            body = {"title": json_response['title'], "body": json_response['body'], "shared_with": [],
                    "timestamp": datetime.now(timezone.utc).isoformat()}
            body['shared_with'].append({
                "name": get_user_full_name("sbain@creativeradicals.com"),
                "user": "sbain@creativeradicals.com",
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "viewed": False,
            })
            body['shared_with'].append({
                "name": get_user_full_name("jjefferson@creativeradicals.com"),
                "user": "jjefferson@creativeradicals.com",
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "viewed": False,
            })
            await database.es_client.index(
                index="global_diag_notifications",
                body=body
            )
            await pagerduty_alert(json_response)
        except Exception as e:
            logs.logging.error(f"Error with notifications: {e}")
            continue

        finally:
            await asyncio.sleep(3600)


async def pagerduty_alert(incident: dict):
    """
    Send an incident alert to PagerDuty via their REST API.
    incident dict must include: title, body, urgency, service_id.
    """
    # # Configuration from environment
    # PD_FROM = os.getenv("PD_From")
    # PD_SERVICE_ID = os.getenv("PD_ID")
    # PD_TOKEN = os.getenv("PD_Token")

    HEADERS = {
        "Authorization": f"Token token={base_config['pagerduty']['token']}",
        "From": base_config['pagerduty']['from'],
        "Content-Type": "application/json",
    }

    payload = {
        "incident": {
            "type": "incident",
            "title": incident["title"],
            "service": {
                "id": base_config['pagerduty']['id'],
                "type": "service_reference"
            },
            "body": {
                "type": "incident_body",
                "details": "Check AI Diagnostic Program for More Information",
            },
            "urgency": incident["urgency"]
        }
    }

    async with aiohttp.ClientSession() as session:
        async with session.post(API_URL,
                                headers=HEADERS,
                                json=payload) as resp:
            text = await resp.text()
            if resp.status != 201:
                # Log out status and body on failure
                print(f"ERROR: status {resp.status}")
                print(f"RESPONSE: {text}", file=sys.stderr)
                resp.raise_for_status()
            else:
                # Optionally return the parsed response
                return await resp.json()


def parse_args(args):
    """
    Extracts state, serviceName, hostAlias, and body from argv.
    """
    state, service_name, host_alias, body = args
    # Replace literal "\n" sequences with real newlines
    body = body.replace("\\n", "\n")
    title = f"{state}: {service_name} @ {host_alias}"
    urgency = "low" if state == "WARNING" else "high"
    return {
        "title": title,
        "body": body,
        "urgency": urgency
    }


@router.get("/notifications/")
async def notifications_api(request: Request):
    user = await read_current_user(request.headers.get("Authorization"))
    if not user['is_mfa_login']:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)

    query = {
        "size": 15,
        "query": {
            "nested": {
                "path": "shared_with",
                "query": {
                    "term": {
                        "shared_with.user": {
                            "value": user['sub']
                        }
                    }
                }
            }
        },
        "sort": [
            {
                "timestamp": {"order": "desc"}
            }
        ]
    }

    results = []
    notifications_db = await database.es_client.search(index="global_diag_notifications", body=query)
    for notification in notifications_db['hits']['hits']:
        results.append({"_id": notification['_id'], **notification['_source']})
    return results


@router.post("/notifications/{msg_id}/view/")
async def mark_notifications_viewed(msg_id: str, request: Request):
    user = await read_current_user(request.headers.get("Authorization"))
    if not user['is_mfa_login']:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)

    body = {
        "query": {
            "bool": {
                "must": [
                    # Filter by document _id:
                    {"term": {"_id": msg_id}},
                    # Then restrict to only nested shared_with entries for this user:
                    {
                        "nested": {
                            "path": "shared_with",
                            "query": {
                                "term": {
                                    "shared_with.user": {
                                        "value": user['sub']
                                    }
                                }
                            }
                        }
                    }
                ]
            }
        },
        "script": {
            "lang": "painless",
            "source": """
              for (int i = 0; i < ctx._source.shared_with.size(); i++) {
                if (ctx._source.shared_with[i].user == params.user) {
                  ctx._source.shared_with[i].viewed = params.viewed;
                  ctx._source.shared_with[i].viewed_at = params.timestamp;
                }
              }
            """,
            "params": {
                "user": user['sub'],
                "viewed": True,
                "timestamp": datetime.now(timezone.utc).isoformat()
            }
        }
    }

    resp = await database.es_client.update_by_query(
        index="global_diag_notifications",
        body=body
    )
    return {"updated": resp.get("updated")}
