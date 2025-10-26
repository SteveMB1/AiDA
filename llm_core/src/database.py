import asyncio
import json
import logging
import socket
import time

import aiohttp
import requests
from elasticsearch import Elasticsearch

logging.basicConfig(level=logging.DEBUG, format='%(asctime)s - %(levelname)s - %(message)s')

hostname = socket.gethostname()

elasticsearch_host = "http://elasticsearch-1:9200"


def connect_elasticsearch():
    try:
        # Create a synchronous Elasticsearch client
        es_client = Elasticsearch(
            elasticsearch_host,
            request_timeout=10,
            max_retries=6,
            retry_on_timeout=True
        )
        # Test the connection
        if es_client.ping():
            logging.info("Connected to Elasticsearch")
        else:
            logging.error("Connection to Elasticsearch failed")
            time.sleep(10)
            return connect_elasticsearch()  # Retry connection
    except Exception as e:
        logging.error(f"Error connecting to Elasticsearch: {e}")
        time.sleep(10)
        return connect_elasticsearch()  # Retry connection
    return es_client


# Initialize the Elasticsearch client
es = connect_elasticsearch()


async def insert_await_async(index, body):
    """
    Inserts data into the index using an await HTTP request.

    Args:
        index (str): The index to insert data into.
        body (dict): The data to be inserted.

    Returns:
        bool: True if the data is inserted successfully, False otherwise.
    """

    # Define the max retries and delay
    max_retries = 3
    retry_delay = 0.2  # 200ms delay between retries

    # Create an aiohttp ClientSession
    async with aiohttp.ClientSession() as session:
        for attempt in range(max_retries):
            try:
                # Use the session to make an await HTTP request
                async with session.post(f"{elasticsearch_host}/{index}/_doc?refresh=wait_for", json=body) as response:
                    response.raise_for_status()  # Raise an exception for bad status codes
                    return True
            except Exception as e:
                if attempt < max_retries - 1:
                    logging.warning(f"Error inserting data into index (attempt {attempt + 1}/{max_retries}): {e}")
                    await asyncio.sleep(retry_delay)
                else:
                    logging.error(f"Failed to insert data into index after {max_retries} attempts: {e}")
                    return False
    return False


def delete_by_query(index: str, query: dict) -> bool:
    """
    Delete documents from an Elasticsearch index based on a query.

    Args:
        index (str): The name of the Elasticsearch index.
        query (dict): The query to delete documents.

    Returns:
        bool: True if the deletion is successful, False otherwise.
    """

    MAX_RETRIES = 3  # Maximum number of retries
    RETRY_DELAY = 1  # Delay between retries in seconds

    # Create the request headers
    headers = {
        'Content-Type': 'application/json',
    }

    # Initialize the retry counter
    retry_count = 0

    while retry_count < MAX_RETRIES:
        try:
            response = requests.post(
                f"{elasticsearch_host}/{index}/_delete_by_query?wait_for_completion=true",
                headers=headers,
                data=json.dumps(query)
            )

            # Check if the request was successful
            status = response.status_code

            if status == 200:
                logging.info("Document deleted successfully.")
                return True
            else:
                logging.error(f"Failed to delete document. Status: {status}")
                logging.error(response.text)
                retry_count += 1
                time.sleep(RETRY_DELAY)
                continue

        except requests.RequestException as e:
            logging.error(f"Requests error: {e}")
            retry_count += 1
            time.sleep(RETRY_DELAY)
            continue
        except Exception as e:
            logging.error(f"An unexpected error occurred: {e}")
            break

    # If all retries fail, return False
    logging.error("Failed to delete document after retries.")
    return False


def delete_job_from_async_generation_jobs(job_uuid):
    try:
        delete_by_query(index="async_generation_jobs", query={
            "query": {
                "bool": {
                    "must": [
                        {"term": {"hostname": hostname}},
                        {"term": {"uuid": job_uuid}},
                    ]
                }
            }
        })
    except Exception as e:
        logging.error(f"Error deleting job from async_generation_jobs: {e}")
