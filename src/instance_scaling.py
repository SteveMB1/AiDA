import asyncio
import json
import logging
import uuid
from collections import defaultdict
from datetime import datetime, timedelta, timezone

import boto3
import yaml
from fastapi import Request, HTTPException, status, BackgroundTasks
from pydantic import BaseModel

import database
import instance_usage_measurement
import logs
from ec2_scaling import scale_instance, append_step, log_to_elasticsearch
from monitoring_status import cluster_status, parse_es_shorthand
from routes import router, read_current_user

try:
    with open("./agent/config.yaml", "r", encoding="utf-8") as file:
        inventory_config = yaml.safe_load(file.read())
except FileNotFoundError:
    logs.logging.warning(f"Warning: config.yaml not found. 'system_prompt' will be empty.")
    raise
except Exception as e:
    logs.logging.error(f"An error occurred reading config.yaml: {e}")
    raise


async def previous_recommendation(instance_id: str):
    response = await database.es_client.search(
        index="scale_recommendations",
        body={
            "size": 1,
            "query": {
                "bool": {
                    "must": [
                        {
                            "term": {
                                "instance_id": instance_id
                            }
                        }
                    ]
                }
            },
            "sort": [
                {"timestamp": "desc"}  # Optional: get the latest recommendation
            ]
        }
    )

    hits = response.get("hits", {}).get("hits", [])
    if hits:
        return hits[0].get("_source")
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


def get_instance_price(instance_type, region='US East (N. Virginia)', os='Linux'):
    pricing = boto3.client('pricing', region_name='us-east-1')
    try:
        response = pricing.get_products(
            ServiceCode='AmazonEC2',
            Filters=[
                {'Type': 'TERM_MATCH', 'Field': 'instanceType', 'Value': instance_type},
                {'Type': 'TERM_MATCH', 'Field': 'location', 'Value': region},
                {'Type': 'TERM_MATCH', 'Field': 'operatingSystem', 'Value': os},
                {'Type': 'TERM_MATCH', 'Field': 'preInstalledSw', 'Value': 'NA'},
                {'Type': 'TERM_MATCH', 'Field': 'tenancy', 'Value': 'Shared'},
                {'Type': 'TERM_MATCH', 'Field': 'capacitystatus', 'Value': 'Used'},
            ],
            MaxResults=1
        )

        if not response['PriceList']:
            return None

        price_item = json.loads(response['PriceList'][0])
        price_dimensions = next(iter(price_item['terms']['OnDemand'].values()))['priceDimensions']
        price_per_hour = next(iter(price_dimensions.values()))['pricePerUnit']['USD']
        return float(price_per_hour)
    except Exception as e:
        print(f"Failed to get price for {instance_type}: {e}")
        return None


def lookup_instance_type(instance_type_name, region_name='us-east-1'):
    ec2 = boto3.client('ec2', region_name=region_name)
    try:
        response = ec2.describe_instance_types(InstanceTypes=[instance_type_name])
        itype = response['InstanceTypes'][0]

        vcpus = itype['VCpuInfo']['DefaultVCpus']
        memory_mib = itype['MemoryInfo']['SizeInMiB']
        memory_gib = round(memory_mib / 1024, 2)

        gpu_info = itype.get('GpuInfo')
        if gpu_info and gpu_info['Gpus']:
            gpus = gpu_info['Gpus'][0]['Count']
            gpu_type = gpu_info['Gpus'][0]['Name']
        else:
            gpus = 0
            gpu_type = 'None'

        price = get_instance_price(instance_type_name)

        return {
            'GPUCount': gpus,
            'GPUType': gpu_type,
            'vCPUs': vcpus,
            'MemoryGiB': memory_gib,
            'PricePerHourUSD': price
        }

    except Exception as e:
        print(f"Failed to retrieve instance type: {e}")
        return {}


@router.get("/scale/recommendation/")
async def scale_recommendation_api(
        request: Request,
        instance_id: str,
        background_tasks: BackgroundTasks,
):
    user = await read_current_user(request.headers.get("Authorization"))
    if not user.get("is_mfa_login"):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED,
                            detail="MFA required")

    if instance_id == "all":
        background_tasks.add_task(scale_recommendation, instance_id="all")
        return {"detail": "Bulk scaling recommendations started."}

    return await scale_recommendation(instance_id=instance_id)


async def scale_recommendation(instance_id: str):
    es = database.get_es_client()
    try:
        if instance_id == "all":
            await es.delete_by_query(
                index="scale_recommendations",
                query={
                    "match_all": {}
                })
            results = await cluster_status(
                start_date=parse_es_shorthand("now-14d"),
                end_date=parse_es_shorthand("now"),
                active_fetch_cloudwatch=False
            )
        else:
            # previous = await previous_recommendation(instance_id=instance_id)
            # if previous:
            #     return previous
            await es.delete_by_query(
                index="scale_recommendations",
                query={
                    "bool": {
                        "must": [
                            {
                                "term": {
                                    "instance_id": instance_id
                                }
                            }
                        ]
                    }
                })
            # 1) pull last 4h of metrics for this instance
            results = {"result": await cluster_status(
                start_date=parse_es_shorthand("now-14d"),
                end_date=parse_es_shorthand("now"),
                instance_id=instance_id,
                active_fetch_cloudwatch=False
            )}

        for instance in results.values():
            if instance.get('Provider', "AWS") == "AWS":
                # 2) describe those volumes in EC2
                ec2 = boto3.client('ec2', region_name=instance['Region'])
                response = ec2.describe_volumes(
                    Filters=[
                        {
                            'Name': 'attachment.instance-id',
                            'Values': [instance['InstanceId']]
                        }
                    ]
                )
                # 3) pull out Size, IOPS and Throughput into a map
                instance['volume_config'] = {
                    vol["VolumeId"]: {
                        "CurrentSizeGB": vol["Size"],
                        "CurrentVolumeType": vol["VolumeType"],
                        "CurrentIops": vol.get("Iops"),  # provisioned IOPS for io1/io2/gp3
                        "CurrentThroughput": vol.get("Throughput")  # max MB/s for gp3
                    }
                    for vol in response["Volumes"]
                }

                # results['AWS_EBS_Config'] = volume_config
                del instance['Tags']

                json_response = instance_usage_measurement.recommend_instance(host=instance)

                # 4) add instance pricing & metadata
                new_specs = {
                    "CurrentInstanceType": instance['InstanceType'],
                    **json_response,
                    **lookup_instance_type(instance_type_name=json_response['NewInstanceType'])
                }
                new_specs['HourlySavings'] = (
                        float(get_instance_price(instance_type=instance['InstanceType']))
                        - float(new_specs['PricePerHourUSD'])
                )
                new_specs['MonthlySavings'] = new_specs['HourlySavings'] * 24 * 30
                new_specs.update({
                    'instance_id': instance['InstanceId'],
                    'timestamp': datetime.now(timezone.utc).isoformat()
                })

                await es.index(
                    index="scale_recommendations",
                    document=new_specs
                )

                if instance_id != "all":
                    return new_specs

        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Issue with generating recommendation, try again later."
        )
    except Exception as e:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"{e}"
        )


@router.get("/instance/info/")
async def instance_info_api(request: Request, instance_type: str, cloud_provider: str):
    # Authenticate user
    user = await read_current_user(request.headers.get("Authorization"))
    if not user.get("is_mfa_login"):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="MFA required")

    return lookup_instance_type(instance_type_name=instance_type)


class ScaleRequest(BaseModel):
    instance_id: str


from fastapi.responses import JSONResponse


@router.post("/scale/confirm/")
async def scale_using_recommendation(request: Request, scale_request: ScaleRequest):
    try:
        es = database.get_es_client()

        user = await read_current_user(request.headers.get("Authorization"))
        if not user.get("is_mfa_login"):
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="MFA required")

        instance_id = scale_request.instance_id
        current_scale_recommendation = await previous_recommendation(instance_id=instance_id)
        if not current_scale_recommendation:
            return JSONResponse(status_code=status.HTTP_404_NOT_FOUND, content={
                "detail": f"Sorry, we couldn't find a valid recommendation for instance {instance_id}. Please try requesting a recommendation again."})

        current_state = await cluster_status(
            start_date=parse_es_shorthand("now-30m"),
            end_date=parse_es_shorthand("now"),
            instance_id=instance_id,
            active_fetch_cloudwatch=False
        )

        try:
            if current_state['Tags'].get('aws:autoscaling:groupName'):
                return JSONResponse(status_code=status.HTTP_403_FORBIDDEN, content={
                    "detail": "Scaling not allowed: this instance belongs to an Auto Scaling group."})
        except KeyError:
            return JSONResponse(status_code=status.HTTP_403_FORBIDDEN, content={
                "detail": "Scaling not allowed: unable to perform safety check on Instance Tags."})

        tag_environment = current_state['Tags'].get("Environment", None)
        region = current_state.get("Region", None)
        tag_progrm = current_state['Tags'].get("Program", None)
        tag_project = current_state['Tags'].get("Project", None)
        safe_to_scale_names = []
        safe_to_scale = []
        not_safe_to_scale_names = []

        status_checks_environments = inventory_config.get('status_checks', {}).get('environments', [])
        for env in status_checks_environments:
            if env.get('project', None) == tag_project and env.get('environment', None) == tag_environment and \
                    current_state['Region'] == env['region'] and region == env['region']:
                if env['programs'][tag_progrm].get('scale_as_group_tag', None):

                    # 1. extract your scale-in tag field and value
                    scale_in_tag = env['programs'][tag_progrm].get('scale_as_group_tag')
                    tags_field = f"Tags.{scale_in_tag}.keyword"
                    tags_value = current_state['Tags'].get(scale_in_tag)

                    must = [
                        {"term": {tags_field: {"value": tags_value}}},
                        {"term": {"Tags.Project.keyword": {"value": tag_project}}},
                        {"term": {"Tags.Environment.keyword": {"value": tag_environment}}},
                        {"term": {"State": {"value": "running"}}},
                        {"term": {"Region": {"value": region}}},
                        {"term": {"Program": {"value": tag_progrm}}},
                        {"term": {"InstanceType": {"value": current_state['InstanceType']}}},
                    ]
                    other_instances = await es.search(
                        index="monitoring_data",
                        size=1000,
                        sort=[
                            {
                                "timestamp": {
                                    "order": "desc"
                                }
                            }
                        ],
                        collapse={
                            "field": "Tags.hostName.keyword"
                        },
                        query={
                            "bool": {
                                "must": must
                            }
                        })
                    for instance in other_instances['hits']['hits']:
                        id = instance['_source']['InstanceId']
                        if id not in safe_to_scale:
                            in_progress_count = await es.count(
                                index="scale_status_log",
                                query={
                                    "bool": {
                                        "must": [
                                            {"term": {"instance_id": id}},
                                            {"term": {"status": "in_progress"}},
                                            {"range": {"lastUpdated": {"gte": "now-30m"}}},
                                        ],
                                        "must_not": [
                                            {"term": {"status": "canceled"}},
                                        ]
                                    }
                                }
                            )
                            if in_progress_count['count'] == 0:
                                safe_to_scale.append(id)
                                safe_to_scale_names.append(instance['_source'].get("name", "Name not Assigned"))
                            else:
                                not_safe_to_scale_names.append(instance['_source'].get("name", "Name not Assigned"))

        async def background_scaling_task():
            try:
                es_doc_ids = {}

                new_instance_type = current_scale_recommendation["NewInstanceType"]

                for group_instance_id in safe_to_scale:
                    es_doc_ids[group_instance_id] = str(uuid.uuid4())
                    await log_to_elasticsearch(es_doc_ids[group_instance_id], group_instance_id, {})
                    await append_step(es_doc_ids[group_instance_id],
                                      f"Scale operation initiated by {user['sub']}, changing to: {new_instance_type}", 0)

                for safe_scale_instance_id in safe_to_scale:
                    await database.delete_by_query(
                        index="scale_recommendations",
                        query={
                            "bool": {
                                "must": [
                                    {
                                        "term": {
                                            "instance_id": safe_scale_instance_id
                                        }
                                    }
                                ]
                            }
                        }
                    )
                    await scale_instance(
                        instance_id=safe_scale_instance_id,
                        new_instance_type=new_instance_type,
                        region=current_state["Region"],
                        es_doc_update_id=es_doc_ids[safe_scale_instance_id]
                    )

            except Exception as e:
                logging.exception(f"Background scaling failed for {instance_id}: {e}")

        final_message = []
        status_code_resp = status.HTTP_200_OK

        if len(not_safe_to_scale_names) > 0:
            not_safe_scale_names_str = ", ".join(not_safe_to_scale_names)
            final_message.append(
                f"You've recently performed a scale up activity on the following hosts {not_safe_scale_names_str}. Please allow 30 minutes before scaling again.")
            status_code_resp = status.HTTP_403_FORBIDDEN

        if len(safe_to_scale_names) > 0:
            asyncio.create_task(background_scaling_task())
            names_str = ", ".join(safe_to_scale_names)
            if len(safe_to_scale_names) > 1:
                final_message.append(
                    f"We've started scaling these resources {names_str} since they are configured for group scaling. This will continue in the background-no further action needed. Track status in Notifications.")
            else:
                final_message.append(
                    f"We've started scaling this resource {names_str}. This will continue in the background-no further action needed. Track status in Notifications.")

            status_code_resp = status.HTTP_200_OK  # Rests to OK since something has passed.

        return JSONResponse(
            status_code=status_code_resp,
            content={
                "detail": " ".join(final_message)
            }
        )

    except Exception as e:
        logging.exception(f"Unexpected error in /scale/confirm/: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Internal server error while preparing scaling operation."
        )


async def calculate_monthly_savings():
    end_date = datetime.now(timezone.utc)
    start_date = end_date - timedelta(days=365)

    query = {
        "query": {
            "range": {
                "timestamp": {
                    "gte": start_date.isoformat(),
                    "lt": end_date.isoformat()
                }
            }
        },
        "sort": [
            {"timestamp": {"order": "asc"}}
        ]
    }

    response = await database.es_client.search(index="previous_scale_history", body=query, size=10000)
    hits = response.get('hits', {}).get('hits', [])

    # Group events by instance
    instance_events = defaultdict(list)
    for hit in hits:
        doc = hit["_source"]
        if all(k in doc for k in ("instance_id", "previous_instance_type", "new_instance_type", "timestamp")):
            instance_events[doc["instance_id"]].append(doc)

    instance_price_cache = {}
    total_savings = 0.0

    for instance_id, events in instance_events.items():
        # Get current instance status
        status = await cluster_status(
            start_date=parse_es_shorthand("now-1h"),
            end_date=parse_es_shorthand("now"),
            instance_id=instance_id,
            active_fetch_cloudwatch=False
        )

        if not status or status.get("InstanceId") != instance_id:
            continue

        current_instance_type = status.get("InstanceType")

        # Sort events by timestamp
        sorted_events = sorted(events, key=lambda x: x["timestamp"])

        for i, event in enumerate(sorted_events):
            prev_type = event["previous_instance_type"]
            new_type = event["new_instance_type"]

            # if new_type != current_instance_type:
            #     continue  # Skip if current instance type isn't this one anymore

            if prev_type == new_type:
                continue  # No actual change

            # Cache prices
            if prev_type not in instance_price_cache:
                try:
                    instance_price_cache[prev_type] = get_instance_price(prev_type)
                except:
                    instance_price_cache[prev_type] = None
            if new_type not in instance_price_cache:
                try:
                    instance_price_cache[new_type] = get_instance_price(new_type)
                except:
                    instance_price_cache[new_type] = None

            prev_price = instance_price_cache.get(prev_type)
            new_price = instance_price_cache.get(new_type)

            if prev_price is None or new_price is None:
                continue

            # Determine how long this change was in effect
            current_time = datetime.fromisoformat(event["timestamp"])
            if i + 1 < len(sorted_events):
                next_time = datetime.fromisoformat(sorted_events[i + 1]["timestamp"])
            elif "expires_at" in event and event["expires_at"]:
                next_time = datetime.fromisoformat(event["expires_at"])
            else:
                next_time = min(end_date, current_time + timedelta(days=30))

            duration_hours = max((next_time - current_time).total_seconds() / 3600, 0)
            savings = (prev_price - new_price) * duration_hours
            total_savings += savings

    return total_savings


# @router.get("/savings/total/")
# async def calculate_monthly_savings_api(request: Request):
#     # Authenticate user
#     user = await read_current_user(request.headers.get("Authorization"))
#     if not user.get("is_mfa_login"):
#         raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="MFA required")
#
#     return {"savings": await calculate_monthly_savings(),
#             "description": "Calculates monthly savings by comparing historical instance type changes over the past year. It checks if instances were downscaled, estimates the duration of each change, and computes the savings based on hourly price differences."}


@router.get("/scaling/status/")
async def scaling_status_api(request: Request):
    # 1) authenticate
    user = await read_current_user(request.headers.get("Authorization"))
    if not user.get("is_mfa_login"):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="MFA required")

    # 2) build the initial log search
    log_query = {
        "query": {"match_all": {}},
        "sort": [{"timestamp": {"order": "desc"}}],
        "size": 50,
    }

    # 3) pull the last 15 logs (sync client off‑loaded)
    resp1 = await database.es_client.search(
        index="scale_status_log",
        body=log_query)

    hits = resp1.get("hits", {}).get("hits", [])
    instance_ids = [
        h["_source"]["instance_id"]
        for h in hits
        if h.get("_source", {}).get("instance_id")
    ]
    if not instance_ids:
        return {"status": []}

    # 4) build the aggregation query against your metrics/index that holds Tags.Name
    now = "now"
    one_hour_ago = "now-1h"
    metrics_query = {
        "size": 0,
        "query": {
            "bool": {
                "filter": [
                    {"range": {"timestamp": {"gte": one_hour_ago, "lte": now}}},
                    {"terms": {"InstanceId": instance_ids}},
                ]
            }
        },
        "aggs": {
            "by_instance": {
                "terms": {"field": "InstanceId", "size": len(instance_ids)},
                "aggs": {
                    "name_tag": {
                        "top_hits": {
                            "size": 1,
                            "_source": ["Tags.Name"]
                        }
                    }
                }
            }
        }
    }

    # 5) bundle into a single msearch payload
    msearch_body = [
        {"index": "scale_status_log"},
        log_query,
        {"index": "monitoring_data"},
        metrics_query,
    ]

    # 6) execute msearch (sync client off‑loaded)
    mresp = await database.es_client.msearch(
        body=msearch_body)

    responses = mresp.get("responses", [])
    if len(responses) < 2:
        # weird: we expected two responses
        return {"status": []}

    log_resp = responses[0]
    metrics_resp = responses[1]

    # pull the logs (always present unless the first query failed)
    log_hits = log_resp.get("hits", {}).get("hits", [])

    # try to pull aggregations
    buckets = []
    if "aggregations" in metrics_resp:
        buckets = metrics_resp["aggregations"] \
            .get("by_instance", {}) \
            .get("buckets", [])
    else:
        # optionally log a warning so you can triage index/name issues
        import logging
        logging.getLogger("instance_scaling").warning(
            "No aggregations in metrics response: %r", metrics_resp
        )

    # build your tag_map only if you got buckets
    tag_map = {}
    for b in buckets:
        hits_tag = b.get("name_tag", {}).get("hits", {}).get("hits", [])
        if hits_tag:
            tag_map[b["key"]] = hits_tag[0]["_source"]["Tags"]["Name"]

    # merge & filter: if tag_map is empty, you'll just drop everything with no name
    final = []
    for hit in log_hits:
        src = hit.get("_source", {})
        inst = src.get("instance_id")
        name = tag_map.get(inst)
        if name:
            src["instance_id"] = name
            final.append(src)

    return {"status": final}


@router.get("/scale/recommendations/")
async def scaling_status_api(request: Request):
    # 1) authenticate
    user = await read_current_user(request.headers.get("Authorization"))
    if not user.get("is_mfa_login"):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="MFA required")

    # 2) build the initial log search
    query = {
        "query": {
            "bool": {
                "must": [
                    {"term": {"changed": True}}
                ]
            }
        },
        "sort": [{"timestamp": {"order": "asc"}}],
        "size": 10000,
    }

    # 3) pull the last 15 logs (sync client off‑loaded)
    resp = await database.es_client.search(
        index="scale_recommendations",
        body=query)

    # pull the logs (always present unless the first query failed)
    hits = resp.get("hits", {}).get("hits", [])
    records = []
    for instance in hits:
        query = {
            "query": {
                "bool": {
                    "must": [
                        {"term": {"InstanceId": instance['_source']['instance_id']}}
                    ]
                }
            },
            "sort": [{"timestamp": {"order": "desc"}}],
            "size": 1,
        }

        instance_data = await database.es_client.search(
            index="monitoring_data",
            body=query
        )

        instance['_source']['name'] = (
            (instance_data.get('hits', {}).get('hits') or [{}])[0]
            .get('_source', {})
            .get('Tags', {})
            .get('Name', "Nameless")
        )
        records.append(instance['_source'])

    return {"results": records}
