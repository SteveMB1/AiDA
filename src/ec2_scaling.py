from datetime import datetime, timezone

import boto3

from database import es_client

# --- Global Configuration ---
ES_INDEX = 'scale_status_log'


async def log_to_elasticsearch(doc_id, instance_id, updates):
    doc = await es_client.get(index=ES_INDEX, id=doc_id, ignore=[404])
    if not doc.get('found'):
        base_doc = {
            'instance_id': instance_id,
            'timestamp': datetime.now(timezone.utc).isoformat(),
            'status': 'in_progress',
            'steps': []
        }
        await es_client.index(index=ES_INDEX, id=doc_id, document=base_doc)

    await es_client.update(
        index=ES_INDEX,
        id=doc_id,
        body={
            'doc': updates,
            'doc_as_upsert': True
        }
    )


async def append_step(doc_id, step, percent_complete, status='in_progress', message=''):
    await es_client.update(
        index=ES_INDEX,
        id=doc_id,
        body={
            "script": {
                "lang": "painless",
                "source": """
                if (ctx._source.steps == null) {
                    ctx._source.steps = [];
                }
                ctx._source.steps.add(params.step);
                ctx._source.status = params.status;
                ctx._source.lastUpdated = params.step.timestamp;
            """,
                "params": {
                    "step": {
                        "timestamp": datetime.now(timezone.utc).isoformat(),
                        "step": step,
                        "percent_complete": percent_complete,
                        "status": status,
                        "message": message
                    },
                    "status": status
                }
            }
        }
    )


async def stop_instance(EC2_CLIENT, doc_id, instance_id):
    await append_step(doc_id, 'Stopping instance', 10)
    EC2_CLIENT.stop_instances(InstanceIds=[instance_id])
    waiter = EC2_CLIENT.get_waiter('instance_stopped')
    waiter.wait(InstanceIds=[instance_id])
    await append_step(doc_id, 'Instance stopped', 30)


async def change_instance_type(EC2_CLIENT, doc_id, instance_id, instance_type):
    await append_step(doc_id, 'Changing instance type', 40)
    EC2_CLIENT.modify_instance_attribute(InstanceId=instance_id, Attribute='instanceType', Value=instance_type)
    await append_step(doc_id, 'Instance type changed', 60)


async def start_instance(EC2_CLIENT, doc_id, instance_id):
    await append_step(doc_id, 'Starting instance', 70)
    EC2_CLIENT.start_instances(InstanceIds=[instance_id])
    waiter = EC2_CLIENT.get_waiter('instance_running')
    waiter.wait(InstanceIds=[instance_id])
    await append_step(doc_id, 'Instance running', 100, status='completed')


# --- Main Function ---
async def scale_instance(instance_id: str, new_instance_type: str, region: str, es_doc_update_id: str):
    EC2_CLIENT = boto3.client(
        'ec2',
        region_name=region,
        # aws_access_key_id=aws_access_key_id,
        # aws_secret_access_key=aws_secret_access_key
    )

    try:
        # await log_to_elasticsearch(es_doc_update_id, instance_id, {})
        # await append_step(es_doc_update_id, 'Scale operation initiated', 0)
        await stop_instance(EC2_CLIENT, es_doc_update_id, instance_id)
        await change_instance_type(EC2_CLIENT, es_doc_update_id, instance_id, new_instance_type)
        await start_instance(EC2_CLIENT, es_doc_update_id, instance_id)
    except Exception as e:
        await append_step(es_doc_update_id, 'Error occurred', 0, status='failed', message=str(e))
        raise
