import json
import logging
import os
import time
import uuid
from datetime import datetime, timezone
from typing import AsyncGenerator, List, Dict
from typing import Optional

import aiohttp
import torch.multiprocessing as mp
import yaml
from elasticsearch import NotFoundError, ConflictError
from fastapi import HTTPException, status
from fastapi import Request
from fastapi.responses import StreamingResponse
from openai import AsyncOpenAI
from pydantic import BaseModel, Field, model_validator

import database
import logs
from dependencies import router, read_current_user

allowed_users = os.environ.get("authorizedUsers", "").split(",")
core_endpoint = os.environ.get("core_endpoint", "")
llm_platform = os.environ.get("llm_platform", "")
OPENAI_MODEL = os.environ.get("OPENAI_MODEL", "")

openai_client = AsyncOpenAI(
    api_key=os.environ.get("OPENAI_API_KEY"),
)

allowed_users_submit_diagnostics = os.environ.get("authorizedUsersSubmitDiagnostics", "").split(",")

max_diagnostic_results = 100
mp.set_start_method("spawn", force=True)


async def stream_chat(
        url: str,
        messages: List[Dict[str, str]],
) -> AsyncGenerator[str, None]:
    """
    Connects to the FastAPI /llm endpoint, sends `messages`,
    and yields each piece of generated text as it arrives.
    """
    headers = {
        "Accept": "text/plain",  # or "text/event-stream" if you switch to SSE
        "Content-Type": "application/json"
    }
    payload = {"messages": messages}

    async with aiohttp.ClientSession() as session:
        async with session.post(url, json=payload, headers=headers) as resp:
            resp.raise_for_status()
            # resp.content is an aiohttp.StreamReader
            async for chunk in resp.content.iter_chunked(64):
                text = chunk.decode("utf-8")
                # you can further split on newlines or JSON-decode if needed
                yield text


def normalize_chat_history(chat_history):
    normalized = []
    for msg in chat_history:
        content = msg.get("content")
        # If content is a dict (invalid), convert to string
        if isinstance(content, dict):
            content = str(content)
        # If content is not string or list, convert to string
        if not isinstance(content, (str, list)):
            content = str(content)
        normalized.append({
            "role": msg["role"],
            "content": content,
        })
    return normalized


async def generate_core(chat_history):
    try:
        if llm_platform == "openai":
            # Get the stream generator directly
            response = await openai_client.chat.completions.create(
                messages=normalize_chat_history(chat_history),
                model=OPENAI_MODEL,
                stream=True,
            )
            async for chunk in response:
                if chunk.choices and chunk.choices[0].delta and chunk.choices[0].delta.content:
                    yield chunk.choices[0].delta.content
        else:
            async for token in stream_chat(url=core_endpoint + "/llm", messages=normalize_chat_history(chat_history)):
                yield token

    except Exception as e:
        logging.error(f"Error in generate_core: {e}")
        yield f"An error occurred while generating the response: {e}"
        raise


async def generate_response_async(options, chat_history, user, is_final_round=False):
    question_asked_timestamp = datetime.now(timezone.utc).isoformat()
    try:
        # if not options['advanced_diagnostic_mode']:
        #     yield json.dumps({"hostname": hostname})
        #     yield '\n'

        previous_summary_search = None
        if is_final_round:
            last_assistant_response = chat_history[-1]['content'] if chat_history[-1]['role'] == "assistant" else ""
            yield last_assistant_response.split('assistant')[-1].strip()
            return

        question = chat_history[-1]['content']

        if options['advanced_diagnostic_mode']:
            query = {
                "bool": {
                    "must": [
                        {
                            "match": {
                                "problem": {
                                    "query": next((message.get("content") for message in chat_history if
                                                   message.get("role") == "user"), None),
                                    "minimum_should_match": "75%"
                                }
                            }
                        }
                    ],
                    "must_not": [
                        {
                            "term": {
                                "advanced_diagnostic_config.tracking_id": options['advanced_diagnostic_config'][
                                    'tracking_id']
                            }
                        }
                    ]
                }
            }

            status_hard_stop_check = await database.es_client.search(index="advanced_diagnostics", query=query)

            if status_hard_stop_check["hits"]["total"]["value"] > 0:
                if any(
                        doc["_source"].get("advanced_diagnostic_config", {}).get("tracking_id") !=
                        options["advanced_diagnostic_config"]["tracking_id"]
                        for doc in status_hard_stop_check["hits"]["hits"]
                ):
                    response_data = {"give_up": True,
                                     "msg": "The diagnostic has already been completed and is stored in the database."}

                    await database.delete_docs_individually(
                        index="advanced_diagnostics",
                        tracking_id=options['advanced_diagnostic_config']['tracking_id'])
                    yield json.dumps(response_data)
                    return

        if options['advanced_diagnostic_mode']:
            query = {
                "bool": {
                    "must": [
                        {
                            "term": {
                                "advanced_diagnostic_config.tracking_id": options['advanced_diagnostic_config'][
                                    'tracking_id']
                            }
                        },
                        {"exists": {"field": "canceled_process"}},
                    ]
                }
            }

            status_hard_stop_check = await database.es_client.count(index="advanced_diagnostics", query=query)

            if status_hard_stop_check.get('count', 0) > 0:
                response_data = {"give_up": True,
                                 "msg": "The diagnostic has been cancelled and is stored in the database."}
                yield json.dumps(response_data)
                return

        if any([
            options.get('internal_codebase_related', False),
            options.get('external_codebase_related', False)
        ]):
            enhanced_prompt = []
            no_systemRole_chat_history = [obj for obj in chat_history if obj.get("role") != "system"]
            new_chat_history = [{
                "role": "user",
                "content": str(no_systemRole_chat_history) + str(os.environ.get("PREVIOUS_SUMMARY_SEARCH_PROMPT"))
            }]

            async for chunk in generate_core(new_chat_history):
                enhanced_prompt.append(chunk)

            previous_summary_search = "".join(enhanced_prompt)

            logs.logging.debug(f"Embedding Search Prompt: {enhanced_prompt}")

            if previous_summary_search.lower() != "skip":
                chat_history = await generate_response_processor(chat_history, previous_summary_search, options)

        chunks = []
        async for chunk in generate_core(chat_history):
            chunks.append(chunk)
            yield chunk

        response = "".join(chunks)

        question_response_timestamp = datetime.now(timezone.utc).isoformat()

        if not options['advanced_diagnostic_mode']:
            if len(chat_history) == 2 or (any([
                options.get('internal_codebase_related', False),
                options.get('external_codebase_related', False)
            ]) and len(chat_history) == 3):
                title_chat_history = [chat_history[0], {
                    "role": "user",
                    "content": 'Summarize this chats with by returning only a valid JSON object in the following format: '
                               '{"title": "short & descriptive title", "emoji": "Use Only Emoji Unicode Version >= 6.0"}'
                               'Do not include any extra text or explanation—just the JSON.'
                }]

                title_response = ""
                attempts = 3
                emoji = "❌"
                title = "No Title"

                for attempt in range(attempts):
                    try:
                        # Clear response each attempt
                        title_response = []

                        # Try to generate and accumulate the response
                        async for chunk in generate_core(title_chat_history):
                            title_response.append(chunk)

                        json_response = json.loads("".join(title_response))

                        emoji = json_response["emoji"]
                        title = json_response["title"]

                        # If we get here, everything worked; break out of the loop
                        break

                    except Exception as e:
                        logs.logging.error(
                            f"Error in generate_core during title generation (attempt {attempt + 1}/{attempts}): {e} {title_response}"
                        )

                await database.es_client.index(
                    index="conversation_settings",
                    body={"user": user, "title": title, "emoji": emoji,
                          "conversation_id": options['conversation_id'],
                          "timestamp": datetime.now(timezone.utc).isoformat()},
                )

            # After Loop End, and conversation settings has been inserted, insert document
            await database.es_client.index(
                index="conversation_history",
                body={"user": user, "role": "user", "content": str(question),
                      "enhanced_question": previous_summary_search,
                      "conversation_id": options['conversation_id'],
                      "timestamp": question_asked_timestamp},
            )
            await database.es_client.index(
                index="conversation_history",
                body={"user": user, "role": "assistant", "content": str(response),
                      "conversation_id": options['conversation_id'],
                      "timestamp": question_response_timestamp},
            )
            response = await database.es_client.search(
                index="conversation_settings",
                size=1,
                body={
                    "query": {
                        "bool": {
                            "must": [
                                {
                                    "term": {
                                        "conversation_id": options['conversation_id']
                                    }
                                }
                            ]
                        }
                    }
                }
            )

            if response["hits"]["total"]["value"] > 0:
                doc_id = response["hits"]["hits"][0]["_id"]
                await database.es_client.update(
                    index="conversation_settings",
                    id=doc_id,
                    body={"doc": {"timestamp": question_response_timestamp}},
                )

        if options['advanced_diagnostic_mode']:
            #     del options['advanced_diagnostic_config']['system_prompt']

            json_data = json.loads(response)

            query = {
                "term": {
                    "advanced_diagnostic_config.tracking_id": options['advanced_diagnostic_config'][
                        'tracking_id']
                }
            }

            doc = await database.es_client.search(index="advanced_diagnostics", query=query, size=1)
            records = doc['hits']['hits']

            if json_data.get('give_up'):
                response_data = {"give_up": True,
                                 "msg": "The diagnostic has been cancelled."}
                await database.delete_docs_individually(
                    index="advanced_diagnostics",
                    tracking_id=options['advanced_diagnostic_config']['tracking_id'])
                yield json.dumps(response_data)
                return

            if len(records) == 0:
                # Create a brand-new document
                doc = {
                    "problem": question,
                    "iterations": [
                        {
                            "descriptions": json_data['description'],
                            "command": str(json_data['ansible_playbook']),
                            "timestamp": datetime.now(timezone.utc).isoformat(),
                        }
                    ],
                    "complete": json_data['complete'],
                    "advanced_diagnostic_config": options['advanced_diagnostic_config'],
                    "lastUpdated": datetime.now(timezone.utc).isoformat()
                }

            else:
                # If we have an existing record, we usually access its _source:
                doc = records[0]['_source']  # the existing document
                # Now update the document’s fields in _source

                doc["iterations"].append({
                    "description": json_data['description'],
                    "command": str(json_data['ansible_playbook']),
                    "timestamp": datetime.now(timezone.utc).isoformat()
                })

                if json_data['complete']:
                    # options['internal_codebase_related'] = True
                    # joined_content = ', '.join([item['content'] for item in chat_history]) + json_data[
                    #     'final_fix_description']
                    # chat_history.append({
                    #     "role": "user",
                    #     "content": "Look at the code provided and come up with a relevant final_fix_description if it's related to the root-cause, "
                    #                "include the issue file path and which line(s) of code to correct. Only respond JSON "
                    #                "format."
                    # })
                    #
                    # chat_history = await generate_response_processor(chat_history, joined_content, options)
                    #
                    # code_response = []
                    # async for chunk in generate_core(chat_history):
                    #     code_response.append(chunk)
                    #
                    # doc['final_fix_description'] = json.loads("".join(code_response))['final_fix_description']
                    doc['final_fix_description'] = json_data['final_fix_description']
                    doc['complete'] = json_data['complete']
                    doc['lastUpdated'] = datetime.now(timezone.utc).isoformat()

            if json_data.get('categories'):
                doc['categories'] = json_data['categories']

            doc_id = options['advanced_diagnostic_config']['tracking_id']

            max_retries = 10

            for attempt in range(max_retries):
                try:
                    # 1) Get current doc
                    res = await database.es_client.get(index="advanced_diagnostics", id=doc_id)
                    seq_no = res['_seq_no']
                    primary_term = res['_primary_term']

                    # 2) Attempt concurrency-checked update
                    await database.es_client.update(
                        index="advanced_diagnostics",
                        id=doc_id,
                        if_seq_no=seq_no,
                        if_primary_term=primary_term,
                        # No retry_on_conflict here
                        body={
                            "script": {
                                "source": "ctx._source.putAll(params.doc)",
                                "lang": "painless",
                                "params": {"doc": doc}
                            }
                        }
                    )

                except NotFoundError:
                    await database.es_client.index(index="advanced_diagnostics", id=doc_id, body=doc)
                    return

                except ConflictError as e:
                    # Another process updated the doc in the meantime -> conflict
                    # Decide whether to retry or fail
                    if attempt < max_retries - 1:
                        # Sleep briefly, then retry
                        time.sleep(0.1)
                    else:
                        logs.logging.error(e)

    except Exception as e:
        logs.logging.error(f"Error generating response: {e}")
        yield f"An error occurred while generating the response: {e}"


async def generate_response_processor(chat_history, previous_summary_search, options):
    try:
        # Extract question from user
        question = chat_history[-1]['content']

        stream_lined_data = []
        unique_documents = set()

        for index in [("internal_codebase_related", "embedding_vectors_internal_codebase"),
                      ("external_codebase_related", "embedding_vectors_external_codebase")]:

            option, index_name = index
            if options.get(option):
                embedding_data = await database.retrieve_closest_embeddings(index_name, question,
                                                                            previous_summary_search)

                for hit in embedding_data['hits']['hits']:
                    doc_id = hit.get('_id')
                    if doc_id not in unique_documents:
                        unique_documents.add(doc_id)
                        stream_lined_data.append(hit['_source'])

        for file in stream_lined_data:
            if file['path'].endswith(('.yml', '.yaml')):
                file['text'] = json.dumps(yaml.safe_load(file['text']), separators=(",", ":"), indent=0).replace("\n",
                                                                                                                 "")
            if file['path'].endswith(('.json', '.html', '.j2')):
                file['text'] = file['text'].replace("\n", "")

        # Append the assistant's response (tool result) to chat history
        chat_history.append({"role": "assistant", "content": str(stream_lined_data)})
        # logs.logging.debug(f"Updated chat history with tool result: {tool_result}")

        return chat_history

    except Exception as e:
        logs.logging.error(f"Error in response processing: {e}")
        return f"An error occurred during response processing: {e}"


class AdvancedDiagnosticConfig(BaseModel):
    environment: str = Field(..., title="Environment", description="Required environment field")
    project: str = Field(..., title="Project", description="Required project field")
    system_prompt: str = Field(..., title="System prompt", description="Required system prompt field")
    tracking_id: str = Field(..., title="UUID to Track status", description="Required UUID field")
    hostname: str = Field(..., title="Machine Hostname", description="Required Hostname field")
    program: str = Field(..., title="Program Running on Host", description="Program on Host field")
    previous_questions: List[str] = Field(..., title="History to Track status",
                                          description="Required Previously Ran Commands")
    previous_answers: List[str] = Field(..., title="History to Track status",
                                        description="Required Previously Returned Commands")


class QARequest(BaseModel):
    conversation_id: Optional[str] = None
    question: str
    internal_codebase_related: bool
    external_codebase_related: bool
    advanced_diagnostic_mode: bool
    advanced_diagnostic_config: Optional[AdvancedDiagnosticConfig] = None

    @model_validator(mode="after")
    def check_advanced_diagnostic_config(cls, values):
        if values.advanced_diagnostic_mode and values.advanced_diagnostic_config is None:
            raise ValueError("advanced_diagnostic_config is required when advanced_diagnostic_mode is True")

        if not values.advanced_diagnostic_mode:
            values.advanced_diagnostic_config = None  # Explicitly set to None if mode is False

        return values


@router.post("/qa/")
async def get_answer_api(request: QARequest, fastapi_request: Request):
    user = await read_current_user(fastapi_request.headers.get("Authorization"))
    if not user['is_mfa_login']:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)

    options = {
        "conversation_id": request.conversation_id,
        "internal_codebase_related": request.internal_codebase_related,
        "external_codebase_related": request.external_codebase_related,
        "advanced_diagnostic_mode": request.advanced_diagnostic_mode,
        "advanced_diagnostic_config": (
            request.advanced_diagnostic_config.model_dump() if request.advanced_diagnostic_config else None
        )
    }

    return StreamingResponse(get_answer(options=options, user=user['sub'], question=request.question),
                             media_type="text/plain")


async def get_answer(options, user, question):
    try:
        # if options['advanced_diagnostic_mode']:
        #     verify_mtls_cert(allowed_users_submit_diagnostics, fastapi_request)
        # else:
        #     verify_mtls_cert(allowed_users, fastapi_request)

        # if not options['advanced_diagnostic_mode']:
        #     verify_mtls_cert(allowed_users, fastapi_request)

        # Define helper function to format chat history
        async def to_chat_format():
            conversation_history = []
            if not options.get('advanced_diagnostic_mode', False):
                conversation_history = [{
                    "role": "system",
                    "content": (
                        "Your name is AiDA."
                        " Your name comes from 'AI and data.' If you don't know an answer, say 'I don't know'."
                        " When answering questions think of any alternative solutions, approaches, and limitations."
                        " When someone gives you code to fix, reply with the fully fixed version of the code. Include everything that was given in the previous message(s)."
                        " You have full access to Creative Radicals' OpeniO platform codebase."
                        " Chat history is erased when the page is refreshed or exited but remains valid for the session. Clicking 'Start New Conversation' clears chat history."
                        " Markdown formatting is optional."
                        f" Today's date is: {datetime.now(timezone.utc).isoformat()}."
                    ),
                }]
                if options['conversation_id'].strip() != "":
                    try:
                        response = await database.es_client.search(
                            index="conversation_history",
                            size=1000,
                            body={
                                "query": {
                                    "bool": {
                                        "must": [
                                            {"term": {"user": user}},
                                            {"term": {"conversation_id": options['conversation_id']}},
                                        ]
                                    }
                                },
                                "sort": [
                                    {"timestamp": {"order": "asc"}}
                                ]
                            }
                        )

                        # Retrieve the first batch of hits
                        hits = response["hits"]["hits"]
                        for hit in hits:
                            conversation_history.append(hit['_source'])

                        if len(hits) == 0:
                            options['conversation_id'] = str(uuid.uuid4())

                    except Exception as e:
                        logs.logging.exception(f"Error retrieving conversation history: {e}")
                        raise HTTPException(status_code=500, detail=str(e))

                else:
                    options['conversation_id'] = str(uuid.uuid4())

                conversation_history.append({
                    "role": "user",
                    "content": question,
                })

                return conversation_history
            elif options.get('advanced_diagnostic_mode', False):
                conversation_history.append({
                    "role": "system",
                    "content": options['advanced_diagnostic_config']['system_prompt'],
                })
                for q, a in zip(options['advanced_diagnostic_config']['previous_questions'],
                                options['advanced_diagnostic_config']['previous_answers']):
                    conversation_history.append({"role": "user", "content": q})
                    conversation_history.append({"role": "assistant", "content": a})
                conversation_history.append({"role": "user", "content": question})
                return conversation_history
            return None

        # Try to generate and accumulate the response
        async for chunk in generate_response_async(options, await to_chat_format(), user):
            yield chunk

    except Exception as e:
        logs.logging.exception("Error in `/qa/` endpoint")
        yield {"error": str(e)}


@router.get("/advanced_diagnostic/items/")
async def get_diagnostic_db_items(fastapi_request: Request):
    user = await read_current_user(fastapi_request.headers.get("Authorization"))
    if not user['is_mfa_login']:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)

    try:
        query = {
            "query": {
                "match_all": {}
                # "bool": {
                #     "must_not": [
                #         {"exists": {"field": "resolution_status"}}
                #     ]
                # }
            },
            "size": max_diagnostic_results,
            "sort": [
                {
                    "lastUpdated": {
                        "order": "desc"
                    }
                }
            ]
        }

        result = await database.es_client.search(index="advanced_diagnostics", body=query)

        results = result['hits']['hits']

        # ssl_client_cert = extractEmailFromSubjectCert(
        #     fastapi_request.headers.get("X-Amzn-Mtls-Clientcert-Subject", "unauthenticated"))

        return results

    except Exception as e:
        logs.logging.exception("Error in `/qa/` endpoint")
        return {"error": str(e)}


@router.post("/advanced_diagnostic/resolve_item/")
async def resolve_diagnostic_db_items(fastapi_request: Request):
    user = await read_current_user(fastapi_request.headers.get("Authorization"))
    if not user['is_mfa_login']:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)

    body = await fastapi_request.json()
    tracking_id = body.get("tracking_id")

    query = {
        "_source": {
            "excludes": []
        },
        "size": 1,
        "query": {
            "bool": {
                "must": [
                    {
                        "term": {
                            "advanced_diagnostic_config.tracking_id": tracking_id
                        }
                    }
                ],
                "must_not": [
                    {
                        "exists": {
                            "field": "resolution_status"
                        }
                    }
                ]
            }
        }
    }

    main_record = await database.es_client.search(index="advanced_diagnostics", body=query)
    records = main_record['hits']['hits']
    doc = {
        "resolution_status": {
            "user": user['sub'],
            "timestamp": datetime.now(timezone.utc).isoformat()
        }
    }
    if not records[0]['_source']['complete']:
        doc['canceled_process'] = {
            "user": user['sub'],
            "timestamp": datetime.now(timezone.utc).isoformat()
        }

    await database.es_client.update(
        index="advanced_diagnostics",
        id=records[0]['_id'],
        body={"doc": doc}
    )

    return {"success": True}


@router.post("/advanced_diagnostic/acknowledge_item/")
async def acknowledge_diagnostic_db_items(fastapi_request: Request):
    user = await read_current_user(fastapi_request.headers.get("Authorization"))
    if not user['is_mfa_login']:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)

    body = await fastapi_request.json()

    tracking_id = body.get("tracking_id")

    query = {
        "_source": {
            "excludes": []
        },
        "size": 1,
        "query": {
            "bool": {
                "must": [
                    {
                        "term": {
                            "advanced_diagnostic_config.tracking_id": tracking_id
                        }
                    }
                ],
                "must_not": [
                    {
                        "exists": {
                            "field": "resolution_status"
                        }
                    }
                ]
            }
        }
    }

    main_record = await database.es_client.search(index="advanced_diagnostics", body=query)
    records = main_record.get('hits', {}).get('hits', [])

    if records:
        record = records[0]
        acknowledgements = record.get('_source', {}).get('acknowledgements') or []

        for person in acknowledgements:
            if person.get('user') == user['sub']:
                return {"acknowledgement": person.get('timestamp')}

        # Append new acknowledgement correctly
        new_acknowledgements = acknowledgements + [
            {"user": user['sub'], "timestamp": datetime.now(timezone.utc).isoformat()}]

        await database.es_client.update(
            index="advanced_diagnostics",
            id=record['_id'],
            body={"doc": {"acknowledgements": new_acknowledgements}}
        )

        return {"success": True}
    return None


@router.post("/advanced_diagnostic/cancel_diagnostic_item/")
async def diagnostics_get_all_unique_categories(fastapi_request: Request):
    user = await read_current_user(fastapi_request.headers.get("Authorization"))
    if not user['is_mfa_login']:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)

    body = await fastapi_request.json()
    tracking_id = body.get("tracking_id")

    query = {
        "_source": {
            "excludes": []
        },
        "size": 1,
        "query": {
            "bool": {
                "must": [
                    {
                        "term": {
                            "advanced_diagnostic_config.tracking_id": tracking_id
                        }
                    }
                ],
                "must_not": [
                    {
                        "exists": {
                            "field": "resolution_status"
                        }
                    },
                    {
                        "term": {
                            "complete": True
                        }
                    }
                ]
            }
        }
    }

    main_record = await database.es_client.search(index="advanced_diagnostics", body=query)
    records = main_record['hits']['hits']

    await database.es_client.update(
        index="advanced_diagnostics",
        id=records[0]['_id'],
        body={
            "doc": {
                "canceled_process": {
                    "user": user['sub'],
                    "timestamp": datetime.now(timezone.utc).isoformat()
                }
            }
        }
    )
    return {"success": True}


class GetMetrics(BaseModel):
    hostname: str


@router.post("/get_metrics/")
async def get_metrics_api(request: GetMetrics, fastapi_request: Request):
    user = await read_current_user(fastapi_request.headers.get("Authorization"))
    if not user['is_mfa_login']:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)

    cluster_wide_running_jobs = await database.es_client.count(index="async_generation_jobs")
    this_host_running_jobs = await database.es_client.count(index="async_generation_jobs", body={
        "query": {
            "term": {
                "hostname": request.hostname
            }
        }
    })
    return {"cluster_wide_running_jobs": cluster_wide_running_jobs['count'],
            "this_host_running_jobs": this_host_running_jobs['count']}


@router.get("/conversation_list/")
async def conversation_history_api(fastapi_request: Request):
    user = await read_current_user(fastapi_request.headers.get("Authorization"))
    if not user['is_mfa_login']:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)

    conversations = await database.es_client.search(index="conversation_settings", body={
        "size": 1000,
        "sort": [
            {"timestamp": {"order": "desc"}}
        ],
        "query": {
            "bool": {
                "should": [
                    {
                        "term": {
                            "user": user['sub']
                        }
                    },
                    {
                        "nested": {
                            "path": "shared_with",
                            "query": {
                                "term": {
                                    "shared_with.user": user['sub']
                                }
                            }
                        }
                    }
                ]
            }
        }
    })

    results = []

    for hit in conversations['hits']['hits']:
        item = hit['_source']

        # Safely get the list; default to empty if missing
        shared_with_list = item.get('shared_with', [])

        # Check if ssl_client_cert is in any element (case-insensitive)
        item['shared_with_me'] = any(
            user['sub'].lower() in sw.get('user', '').lower()
            for sw in shared_with_list
        )

        # Remove the 'shared_with' key if it exists and not equal to the user who created the conversation
        if 'shared_with' in item and user['sub'] != item['user']:
            del item['shared_with']

        results.append(item)
    return results


class GetConversation(BaseModel):
    conversation_id: str


@router.post("/conversation/")
async def conversation_api(request: GetConversation, fastapi_request: Request):
    user = await read_current_user(fastapi_request.headers.get("Authorization"))
    if not user['is_mfa_login']:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)

    all_results = []

    shared_with_me = await database.es_client.count(index="conversation_settings", body={
        "query": {
            "bool": {
                "must": [
                    {"term": {"conversation_id": request.conversation_id}}
                ],
                "should": [
                    {"term": {"user": user['sub']}},
                    {
                        "nested": {
                            "path": "shared_with",
                            "query": {
                                "bool": {
                                    "must": [
                                        {"term": {"shared_with.user": user['sub']}}
                                    ]
                                }
                            }
                        }
                    }
                ],
                "minimum_should_match": 1
            }
        }
    })

    if shared_with_me.get('count', 0) > 0:
        # Initial search request
        response = await database.es_client.search(
            index="conversation_history",
            size=1000,
            body={
                "query": {
                    "bool": {
                        "must": [
                            {"term": {"conversation_id": request.conversation_id}},
                        ]
                    }
                },
                "sort": [
                    {"timestamp": {"order": "asc"}}
                ]
            }
        )

        hits = response["hits"]["hits"]
        for hit in hits:
            all_results.append(hit['_source'])

    return all_results


@router.post("/delete_conversation/")
async def conversation_delete_api(request: GetConversation, fastapi_request: Request):
    user = await read_current_user(fastapi_request.headers.get("Authorization"))
    if not user['is_mfa_login']:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)

    query = {
        "bool": {
            "must": [
                {
                    "term": {
                        "user": user['sub']
                    }
                },
                {
                    "term": {
                        "conversation_id": request.conversation_id
                    }
                }
            ]
        }
    }

    await database.delete_by_query(index="conversation_settings", query=query)
    await database.delete_by_query(index="conversation_history", query=query)

    return {"success": True}


class SharedWithEntry(BaseModel):
    user: str


class ConversationShareWith(BaseModel):
    conversation_id: str
    shared_with: list[SharedWithEntry]


@router.post("/share_with/")
async def conversation_share_with_api(request: ConversationShareWith, fastapi_request: Request):
    user = await read_current_user(fastapi_request.headers.get("Authorization"))
    if not user['is_mfa_login']:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)

    query = {
        "query": {
            "bool": {
                "must": [
                    {
                        "term": {
                            "user": user['sub']
                        }
                    },
                    {
                        "term": {
                            "conversation_id": request.conversation_id
                        }
                    }
                ]
            }
        },
    }

    # Initial search request
    response = await database.es_client.search(
        index="conversation_settings",
        size=1,
        body=query
    )

    shared_with = []

    for user_list in request.shared_with:
        if user['sub'] != user_list.user.lower():
            shared_with.append(
                {"user": user_list.user.lower(), "timestamp": datetime.now(timezone.utc).isoformat()})

    await database.es_client.update(
        index="conversation_settings",
        id=response["hits"]["hits"][0]['_id'],
        body={
            "doc": {
                "shared_with": shared_with
            }
        }
    )

    return {"success": True}


@router.post("/unshare_with_me/")
async def conversation_unshare_with_api(request: GetConversation, fastapi_request: Request):
    user = await read_current_user(fastapi_request.headers.get("Authorization"))
    if not user['is_mfa_login']:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)
    query = {
        "query": {
            "bool": {
                "must": [
                    {"term": {"conversation_id": request.conversation_id}},
                    {
                        "nested": {
                            "path": "shared_with",
                            "query": {
                                "bool": {
                                    "must": [
                                        {"term": {"shared_with.user": user['sub']}}
                                    ]
                                }
                            }
                        }
                    }
                ]
            }
        }
    }

    # Initial search request
    response = await database.es_client.search(
        index="conversation_settings",
        size=1,
        body=query
    )

    shared_with = response["hits"]["hits"][0]["_source"]["shared_with"]

    await database.es_client.update(
        index="conversation_settings",
        id=response["hits"]["hits"][0]['_id'],
        body={
            "doc": {
                "shared_with": [u for u in shared_with if u['user'].lower() != user['sub']]
            }
        }
    )

    return {"success": True}


@router.get("/me/")
async def read_current_user_api(fastapi_request: Request):
    return await read_current_user(fastapi_request.headers.get("Authorization"))
