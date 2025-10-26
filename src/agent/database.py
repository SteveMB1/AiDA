import logging
import time

from elasticsearch import AsyncElasticsearch

elasticsearch_host = "http://elasticsearch-1:9200"

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

es_client = AsyncElasticsearch(
    hosts=[elasticsearch_host],
    request_timeout=30,
    max_retries=6,
    retry_on_timeout=True
)


async def connect_elasticsearch():
    try:
        # Test the connection
        if await es_client.ping():
            logging.info("Connected to Elasticsearch")
        else:
            logging.error("Connection to Elasticsearch failed")
            time.sleep(10)
            return await connect_elasticsearch()  # Retry connection
    except Exception as e:
        logging.error(f"Error connecting to Elasticsearch: {e}")
        time.sleep(10)
        return await connect_elasticsearch()  # Retry connection
    return es_client


async def insert_doc(doc):
    return await es_client.index(index="monitoring_data", document=doc)


async def create_indexes():
    if not await es_client.indices.exists(index="monitoring_data"):
        await es_client.indices.create(index="monitoring_data", body={
            "settings": {
                "number_of_shards": 1,
                "number_of_replicas": 1,
            },
            "mappings": {
                "properties": {
                    "name": {"type": "keyword"},
                    # ---- top‑level fields -----------------------------------------
                    "ip": {"type": "ip"},
                    "Program": {"type": "keyword"},
                    "InstanceType": {"type": "keyword"},
                    "InstanceId": {"type": "keyword"},
                    "Region": {"type": "keyword"},
                    "State": {"type": "keyword"},
                    "Provider": {"type": "keyword"},
                    "timestamp": {"type": "date"},
                    "Tags": {
                        "dynamic": True,
                        "type": "object",
                    },
                    "stats": {
                        "properties": {
                            "ok": {"type": "integer"},
                            "processed": {"type": "integer"},
                            "failures": {"type": "integer"},
                            "skipped": {"type": "integer"},
                            "unreachable": {"type": "integer"},
                        }
                    },

                    # ---- tasks array ----------------------------------------------
                    "tasks": {
                        "type": "nested",
                        "dynamic": True,  # allow any module‑specific args
                    },

                    # ---- raw payload catch‑all (stored, not indexed) --------------
                    "raw": {"type": "object", "enabled": False},
                },
            },
        })
    print(f"Index 'monitoring_data' created successfully with specified settings.")


async def diagnostics_get_all_unique_categories():
    """ Retrieves all unique categories from Elasticsearch using composite aggregation pagination,
        sorts them by doc_count, and returns a list of category names only.
    """

    category_counts = {}  # Dictionary to store category counts
    after_key = None  # Pagination key for composite aggregation

    while True:
        # Define the composite aggregation query with pagination
        composite_query = {
            "size": 0,
            "aggs": {
                "unique_categories": {
                    "composite": {
                        # "size": max_diagnostic_results,
                        "sources": [
                            {
                                "category": {
                                    "terms": {"field": "categories"}
                                }
                            }
                        ]
                    }
                }
            }
        }

        # Include pagination key if it exists
        if after_key:
            composite_query["aggs"]["unique_categories"]["composite"]["after"] = after_key

        # Execute the search query
        response = await es_client.search(index="advanced_diagnostics", body=composite_query)

        # Extract unique categories and their document counts
        buckets = response["aggregations"]["unique_categories"]["buckets"]
        for bucket in buckets:
            category = bucket["key"]["category"]
            doc_count = bucket["doc_count"]
            category_counts[category] = category_counts.get(category, 0) + doc_count  # Sum up counts

        # If there are no more results, break the loop
        if "after_key" not in response["aggregations"]["unique_categories"]:
            break

        # Update after_key for next page
        after_key = response["aggregations"]["unique_categories"]["after_key"]

    # Sort categories by doc_count in descending order and return only category names
    sorted_categories = [category for category, _ in sorted(category_counts.items(), key=lambda x: x[1], reverse=True)]

    return {"categories": sorted_categories}
