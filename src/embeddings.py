import aiohttp
import torch
import torch.nn.functional as F

import database
import logs
import routes


def average_pool(last_hidden_states: torch.Tensor, attention_mask: torch.Tensor) -> torch.Tensor:
    """
    Performs mean pooling on transformer outputs.
    last_hidden_states: [batch, seq_len, hidden]
    attention_mask:     [batch, seq_len]
    """
    # expand mask from [batch,seq] to [batch,seq,hidden]
    mask_expanded = (
        attention_mask
        .unsqueeze(-1)
        .expand(last_hidden_states.size())
        .float()
    )
    summed = torch.sum(last_hidden_states * mask_expanded, dim=1)
    counts = torch.clamp(mask_expanded.sum(dim=1), min=1e-9)
    return summed / counts  # [batch, hidden]


async def generate_embedding(document: str, state: str):
    """
    Generates an embedding for Elasticsearch indexing.
    :param document: The input text
    :param state:    "IMPORT_CODE" or "QA"
    :return:         A list-of-lists of floats: [[…], …]
    """
    if state == 'IMPORT_CODE':
        instruction = ""
    elif state == "QA":
        instruction = "Retrieve information based on the following question: "
    else:
        raise ValueError(f"Unsupported state: {state}")

    input_text = instruction + document

    # 1. Call your FastAPI endpoint
    async with aiohttp.ClientSession() as session:
        async with session.post(
                routes.core_endpoint + "/embedding",
                json={
                    "embedding_model": "intfloat/e5-large-v2",
                    "text": input_text
                }
        ) as resp:
            resp.raise_for_status()
            outputs = await resp.json()

    # 2. Rebuild Torch tensors from the JSON lists
    last_hidden = torch.tensor(outputs["last_hidden_state"])  # [batch, seq, hidden]
    attn_mask = torch.tensor(outputs["attention_mask"])  # [batch, seq]

    # 3. Mean‑pool and normalize
    embeddings = average_pool(last_hidden, attn_mask)  # [batch, hidden]
    embeddings = F.normalize(embeddings, p=2, dim=1)  # L2‑norm

    single_emb = embeddings.squeeze(0)

    # 4. Return a pure Python nested list of floats
    return single_emb.cpu().tolist()


async def import_embeddings(documents, index, state):
    documents_count = len(documents)
    process_count = 0

    # Initialize the vector index in the database
    database.set_vector_index(index)

    for document in documents:
        try:
            code_summary = ""
            new_chat_history = [{"role": "assistant", "content": str(document)}, {
                "role": "user",
                "content": "Create a concise description for this code in the latest question."
                           " Explain how the code is used, what it does, and also how to interact with it."
                           " If there are variables developers will need to know please include, along with an explanation of their purpose."
            }]

            async for chunk in routes.generate_core(new_chat_history):
                if chunk:
                    code_summary += chunk

            document['code_summary'] = code_summary

            # Generate embedding for the document text
            description_embedding = await generate_embedding(code_summary, state)
            document['vector_embedding'] = description_embedding

            code_embedding = await generate_embedding(str(document), state)
            document['code_vector_embedding'] = code_embedding

            # Save the generated embedding to the database
            await database.save_embeddings(index, document)

            # Update progress
            process_count += 1
            progress_percent = round((process_count / documents_count) * 100, 2)
            logs.logging.debug(f"saving embedding to database - {progress_percent}%")
        except Exception as e:
            print(f"Error processing document: {e}")
