#!/usr/bin/env python3

import argparse
import json
from elasticsearch import Elasticsearch, helpers

# Adjust these if your Elasticsearch is not on localhost:9200
ES_HOSTS = ["http://elasticsearch-1:9200"]

# Indices to export/import
INDICES = ["conversation_settings", "conversation_history"]

# Corresponding local filenames
BACKUP_FILES = {
    "conversation_settings": "conversation_settings_backup.json",
    "conversation_history": "conversation_history_backup.json"
}


def export_index(es, index_name, output_file):
    """
    Exports all documents from an Elasticsearch index to a JSON lines file.
    Each line in the file will be one JSON object with metadata and source.
    """
    print(f"Exporting index '{index_name}' to file '{output_file}'...")
    # Use helpers.scan if you want to handle large data sets without size limits
    scan_response = helpers.scan(
        client=es,
        index=index_name,
        query={"query": {"match_all": {}}},  # or any other query
        preserve_order=False,    # set True if you need sorted
        scroll='2m'             # scroll timeout
    )

    with open(output_file, 'w', encoding='utf-8') as f:
        count = 0
        for doc in scan_response:
            # doc has keys like _index, _type, _id, _score, _source
            f.write(json.dumps(doc) + "\n")
            count += 1

    print(f"Finished exporting {count} documents from '{index_name}'.")


def import_index(es, index_name, input_file):
    """
    Reads a JSON lines file and bulk-imports documents into an Elasticsearch index.
    The file is expected to contain lines written by export_index() above.
    """
    print(f"Importing file '{input_file}' into index '{index_name}'...")
    actions = []
    count = 0

    with open(input_file, 'r', encoding='utf-8') as f:
        for line in f:
            doc = json.loads(line)
            # Prepare a bulk action
            action = {
                "_index": index_name,
                "_id": doc["_id"],         # keep the same _id
                "_source": doc["_source"], # the actual document content
            }
            actions.append(action)
            count += 1

    # Bulk import in Elasticsearch
    if actions:
        helpers.bulk(es, actions)
    print(f"Finished importing {count} documents into '{index_name}'.")


def main():
    parser = argparse.ArgumentParser(
        description="Export or import specified Elasticsearch indices to/from JSON files."
    )
    parser.add_argument("mode", choices=["export", "import"],
                        help="Choose 'export' to dump data to JSON files, or 'import' to restore from JSON files.")
    args = parser.parse_args()

    # Initialize the Elasticsearch client
    es = Elasticsearch(ES_HOSTS)

    if args.mode == "export":
        # Export each index to a local JSON file
        for idx in INDICES:
            export_index(es, idx, BACKUP_FILES[idx])

    elif args.mode == "import":
        # Import each index from its local JSON file
        for idx in INDICES:
            import_index(es, idx, BACKUP_FILES[idx])


if __name__ == "__main__":
    main()
