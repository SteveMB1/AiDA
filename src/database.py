import asyncio
import logging
import os
import socket
from datetime import datetime
from typing import Any

from elastic_transport import ObjectApiResponse
from elasticsearch import AsyncElasticsearch

import embeddings

batchSize = int(os.environ.get("db_batchSize", 5))
hostname = socket.gethostname()

elasticsearch_host = os.environ.get("elasticsearch_host")
logging.basicConfig(level=logging.DEBUG, format='%(asctime)s - %(levelname)s - %(message)s')

es_client = AsyncElasticsearch(
    hosts=[elasticsearch_host],
    request_timeout=10,
    max_retries=6,
    retry_on_timeout=True
)


def get_es_client() -> AsyncElasticsearch:
    """
    Return an AsyncElasticsearch bound to *this* event-loop.

    The client is cached on the loop object itself so:
    – we create it only once per process-loop combo
    – it is automatically garbage-collected when the loop ends
    """
    loop = asyncio.get_running_loop()
    if not hasattr(loop, "_es_client"):
        loop._es_client = AsyncElasticsearch(
            hosts=[elasticsearch_host],
            request_timeout=10,
            max_retries=6,
            retry_on_timeout=True
        )
    return loop._es_client


async def create_indexes_main():
    try:
        if not await es_client.indices.exists(index='scale_status_log'):
            await es_client.indices.create(
                index='scale_status_log',
                body={
                    "mappings": {
                        "properties": {
                            "instance_id": {"type": "keyword"},
                            "timestamp": {"type": "date"},
                            "status": {"type": "keyword"},
                            "steps": {
                                "type": "nested",
                                "properties": {
                                    "timestamp": {"type": "date"},
                                    "step": {"type": "text"},
                                    "percent_complete": {"type": "integer"},
                                    "status": {"type": "keyword"},
                                    "message": {"type": "text"}
                                }
                            }
                        }
                    }
                }
            )

        if not await es_client.indices.exists(index="advanced_diagnostics"):
            await es_client.indices.create(index="advanced_diagnostics", body={
                "mappings": {
                    "properties": {
                        "problem": {
                            "type": "text"  # Supports arrays of text
                        },
                        "categories": {
                            "type": "keyword"
                        },
                        "iterations": {
                            "type": "nested",
                            "properties": {
                                "description": {
                                    "type": "text"
                                },
                                "command": {
                                    "type": "text"
                                },
                                "timestamp": {
                                    "type": "date"
                                }
                            }
                        },
                        "complete": {
                            "type": "boolean"
                        },
                        "lastUpdated": {
                            "type": "date"
                        },
                        "acknowledgements": {
                            "type": "nested",
                            "properties": {
                                "user": {
                                    "type": "keyword"  # UUID stored as keyword
                                },
                                "timestamp": {
                                    "type": "date"
                                },
                            }
                        },
                        "resolution_status": {
                            "type": "object",
                            "properties": {
                                "user": {
                                    "type": "keyword"  # UUID stored as keyword
                                },
                                "timestamp": {
                                    "type": "date"
                                },
                            }
                        },
                        "canceled_process": {
                            "type": "object",
                            "properties": {
                                "user": {
                                    "type": "keyword"  # UUID stored as keyword
                                },
                                "timestamp": {
                                    "type": "date"
                                },
                            }
                        },
                        "final_fix_description": {
                            "type": "text"
                        },
                        "advanced_diagnostic_config": {
                            "type": "object",
                            "properties": {
                                "tracking_id": {
                                    "type": "keyword"  # UUID stored as keyword
                                },
                                "environment": {
                                    "type": "keyword"  # Stored as keyword for exact matches & filtering
                                },
                                "project": {
                                    "type": "keyword"  # Stored as keyword for exact matches & filtering
                                },
                                "hostname": {
                                    "type": "keyword"  # Stored as keyword for exact matches & filtering
                                },
                                "Program": {
                                    "type": "keyword"  # Stored as keyword for exact matches & filtering
                                }
                            }
                        }
                    }
                }
            })
            print(f"Index 'advanced_diagnostics' created successfully with specified settings.")

        if not await es_client.indices.exists(index="async_generation_jobs"):
            await es_client.indices.create(index="async_generation_jobs", body={
                "mappings": {
                    "properties": {
                        "hostname": {
                            "type": "keyword"
                        },
                        "uuid": {
                            "type": "keyword"
                        }
                    }
                }
            })
            print(f"Index 'async_generation_jobs' created successfully with specified settings.")

        if not await es_client.indices.exists(index="conversation_history"):
            await es_client.indices.create(index="conversation_history", body={
                "mappings": {
                    "properties": {
                        "user": {
                            "type": "keyword"
                        },
                        "role": {
                            "type": "keyword"
                        },
                        "content": {
                            "type": "text"
                        },
                        "enhanced_question": {
                            "type": "text"
                        },
                        "conversation_id": {
                            "type": "keyword"
                        },
                        "timestamp": {
                            "type": "date"
                        },
                    }
                }
            })
            print(f"Index 'conversation_history' created successfully with specified settings.")

        if not await es_client.indices.exists(index="conversation_settings"):
            await es_client.indices.create(index="conversation_settings", body={
                "mappings": {
                    "properties": {
                        "user": {
                            "type": "keyword"
                        },
                        "title": {
                            "type": "keyword"
                        },
                        "emoji": {
                            "type": "keyword"
                        },
                        "conversation_id": {
                            "type": "keyword"
                        },
                        "shared_with": {
                            "type": "nested",
                            "properties": {
                                "user": {"type": "keyword"},
                                "timestamp": {"type": "date"}
                            },
                        },
                        "timestamp": {
                            "type": "date"
                        },
                    }
                }
            })
            print(f"Index 'conversation_settings' created successfully with specified settings.")

        if not await es_client.indices.exists(index="global_diag_notifications"):
            await es_client.indices.create(index="global_diag_notifications", body={
                "mappings": {
                    "properties": {
                        "title": {
                            "type": "keyword"
                        },
                        "body": {
                            "type": "keyword"
                        },
                        "shared_with": {
                            "type": "nested",
                            "properties": {
                                "user": {"type": "keyword"},
                                "name": {
                                    "type": "nested",
                                    "properties": {
                                        "first": {"type": "keyword"},
                                        "last": {"type": "keyword"}
                                    },
                                },
                                "timestamp": {"type": "date"},
                                "viewed": {"type": "boolean"},
                            },
                        },
                        "timestamp": {
                            "type": "date"
                        },
                    }
                }
            })
            print(f"Index 'global_diag_notifications' created successfully with specified settings.")

        if not await es_client.indices.exists(index="users_otp"):
            await es_client.indices.create(index="users_otp", body={
                "mappings": {
                    "properties": {
                        "user": {
                            "type": "keyword"
                        },
                        "pending": {
                            "type": "boolean"
                        },
                        "secret": {
                            "type": "keyword"
                        },
                    }
                }
            })
            print(f"Index 'users_otp' created successfully with specified settings.")

        if not await es_client.indices.exists(index="scale_recommendations"):
            await es_client.indices.create(index="scale_recommendations", body={
                "mappings": {
                    "dynamic": True,
                    "properties": {
                        "instance_id": {"type": "keyword"},
                        "timestamp": {"type": "date"},
                        "expires_at": {"type": "date"}
                    }
                }
            })
            print(f"Index 'scale_recommendations' created successfully with specified settings.")

        if not await es_client.indices.exists(index="previous_scale_history"):
            await es_client.indices.create(index="previous_scale_history", body={
                "mappings": {
                    "properties": {
                        "new_instance_type": {
                            "type": "keyword"
                        },
                        "previous_instance_type": {
                            "type": "keyword"
                        },
                        "instance_id": {
                            "type": "keyword"
                        },
                        "timestamp": {
                            "type": "date"
                        }
                    }
                }
            })
            print(f"Index 'previous_scale_history' created successfully with specified settings.")

        if not await es_client.indices.exists(index="ec2_metrics"):
            await es_client.indices.create(index="ec2_metrics", body={
                "mappings": {
                    "properties": {
                        "timestamp": {
                            "type": "date",
                            "format": "strict_date_optional_time||epoch_millis"
                        },
                        "value": {
                            "type": "float"
                        },
                        "unit": {
                            "type": "keyword"
                        },
                        "instance_id": {
                            "type": "keyword"
                        },
                        "metric": {
                            "type": "keyword"
                        },
                        "volume_id": {
                            "type": "keyword"
                        },
                        "partition": {
                            "type": "keyword"
                        }
                    }
                }
            })
            print(f"Index 'ec2_metrics' created successfully with specified settings.")

        return es_client
        # else:
        #     logging.error("Connection to Elasticsearch failed, retrying in 10s...")
        #     await es_client.close()
        #     await asyncio.sleep(10)
        #     return await connect_elasticsearch()

    except Exception as e:
        logging.error(f"Error connecting to Elasticsearch: {e}, retrying in 10s...")
        await asyncio.sleep(10)
        return await create_indexes_main()


async def delete_by_query(index: str, query: dict) -> ObjectApiResponse[Any]:
    es = get_es_client()
    return await es.delete_by_query(index=index, query=query)


async def index_count(search_id):
    index_id = "embedding_vectors_" + search_id

    query = {
        "query": {
            "bool": {
                "must": [
                    {
                        "exists": {
                            "field": "embedding"
                        },
                    }
                ]
            }
        }
    }

    try:
        response = await es_client.count(index=index_id, body=query)
        return response['count']
    except:
        return 0


async def set_vector_index(SEARCH_ID):
    SEARCH_ID = "embedding_vectors_" + SEARCH_ID
    settings = {
        "settings": {
            "analysis": {
                "analyzer": {
                    "case_insensitive_analyzer": {
                        "type": "custom",
                        "tokenizer": "standard",
                        "filter": ["lowercase"]
                    }
                }
            }
        },
        "mappings": {
            "properties": {
                "vector_embedding": {
                    "type": "dense_vector",
                    "dims": 1024,
                    "index": True,
                    "similarity": "cosine"
                },
                "code_vector_embedding": {
                    "type": "dense_vector",
                    "dims": 1024,
                    "index": True,
                    "similarity": "cosine"
                },
                "timestamp": {
                    "type": "date"
                },
                "text": {
                    "type": "text",
                    "analyzer": "case_insensitive_analyzer"
                },
                "enhanced_question": {
                    "type": "text",
                    "analyzer": "case_insensitive_analyzer"
                },
                "code_summary": {
                    "type": "text",
                    "analyzer": "case_insensitive_analyzer"
                },
                "path": {
                    "type": "text",
                    "analyzer": "case_insensitive_analyzer",
                    "fields": {
                        "keyword": {
                            "type": "keyword"
                        }
                    }
                }
            }
        }
    }

    if not await es_client.indices.exists(index=SEARCH_ID):
        await es_client.indices.create(index=SEARCH_ID, body=settings)
        print(f"Index '{SEARCH_ID}' created successfully with specified settings.")


async def audit_log_diagnostic(data: object):
    index_id = "audit_advanced_diagnostics"

    data['timestamp'] = datetime.now()

    return await es_client.index(index=index_id, body=data)


async def advanced_diagnostic_progress(data: object):
    index_id = "advanced_diagnostics"

    data['timestamp'] = datetime.now()
    # data['vector_embedding'] = embeddings.generate_embedding(str(data['text']), "QA")
    # data['token_length'] = count_tokens(str(data['text']))

    await es_client.index(index=index_id, body=data)


async def retrieve_closest_embeddings(index_id, prompt, previous_summary_search):
    query = {
        "_source": {
            "excludes": ["vector_embedding", "token_length", "code_summary", "code_vector_embedding"]
        },
        "size": batchSize,
        "query": {
            "bool": {
                "should": [
                    {
                        "knn": {
                            "field": "vector_embedding",
                            "query_vector": await embeddings.generate_embedding(str(previous_summary_search), "QA"),
                            "k": batchSize,
                            "num_candidates": 100,
                        }
                    },
                    {
                        "knn": {
                            "field": "code_vector_embedding",
                            "query_vector": await embeddings.generate_embedding(str(previous_summary_search), "QA"),
                            "k": batchSize,
                            "num_candidates": 100,
                        }
                    }
                ],
                "minimum_should_match": 1
            }
        },
        "sort": [
            {"_score": "desc"}
        ],
        "collapse": {
            "field": "path.keyword"
        }
    }

    response = await es_client.search(index=index_id, body=query)
    return response


async def scheduled_deletion():
    while True:
        await delete_by_query(index="advanced_diagnostics", query={"query": {
            "bool": {
                "must": [
                    {"term": {"complete": False}},
                    {"range": {"lastUpdated": {"lt": "now-60m"}}}
                ]
            }
        }})

        await delete_by_query(
            index="scale_recommendations",
            query={"query": {
                "bool": {
                    "must": [
                        {
                            "range": {
                                "timestamp": {
                                    "lt": "now-24h"
                                }
                            }
                        }
                    ]
                }
            }})

        await delete_by_query(
            index="ec2_metrics",
            query={"query": {
                "bool": {
                    "must": [
                        {
                            "range": {
                                "timestamp": {
                                    "lt": "now-31d"
                                }
                            }
                        }
                    ]
                }
            }})

        await delete_by_query(
            index="monitoring_data",
            query={"query": {
                "bool": {
                    "must": [
                        {
                            "range": {
                                "timestamp": {
                                    "lt": "now-31d"
                                }
                            }
                        }
                    ]
                }
            }})

        await asyncio.sleep(60 * 60)  # Sleep for 31 minutes


async def delete_docs_individually(index, tracking_id):
    """
    Searches for documents in the given index that match the 'advanced_diagnostic_config.tracking_id'
    and then deletes them one by one using their '_id'.
    """
    # Define the query
    query_body = {
        "query": {
            "term": {
                "advanced_diagnostic_config.tracking_id": tracking_id
            }
        }
    }

    # Initialize a scroll search to retrieve all matching documents (if many)
    # You can adjust 'size' and 'scroll' as needed
    search_response = await es_client.search(
        index=index,
        body=query_body,
        scroll='1m',  # Time to keep the search context alive
        size=1000  # Number of documents per batch
    )

    # Loop until there are no more hits
    while True:
        scroll_id = search_response['_scroll_id']
        hits = search_response['hits']['hits']

        if not hits:
            # No more documents
            break

        # Delete documents one-by-one using their _id
        for doc in hits:
            doc_id = doc['_id']
            await es_client.delete(index=index, id=doc_id)

        # Fetch the next batch of results
        search_response = await es_client.scroll(scroll_id=scroll_id, scroll='1m')

    # Clear the scroll context
    if 'scroll_id' in locals():
        await es_client.clear_scroll(scroll_id=scroll_id)
