import logging
import os
from typing import List
from typing import Literal

import torch
from pydantic import BaseModel
from transformers import AutoTokenizer, AutoModel

from routes import router

os.environ["TOKENIZERS_PARALLELISM"] = "false"

# Load the tokenizer and model from Hugging Face
embedding_model = os.environ.get("EMBEDDING_MODEL", "intfloat/e5-large-v2")
model = AutoModel.from_pretrained(embedding_model)
tokenizer = AutoTokenizer.from_pretrained(embedding_model)

logging.basicConfig(level=logging.DEBUG, format='%(asctime)s - %(levelname)s - %(message)s')


class ModelRequest(BaseModel):
    embedding_model: Literal["intfloat/e5-large-v2"]
    text: str


class EmbeddingResponse3D(BaseModel):
    # batch_size × seq_length × hidden_size
    last_hidden_state: List[List[List[float]]]
    attention_mask: List[List[int]]


@router.post("/embedding", response_model=EmbeddingResponse3D)
def generate_embedding(req: ModelRequest):
    batch = tokenizer(
        req.text,
        max_length=512,
        padding=True,
        truncation=True,
        return_tensors="pt",
    )

    with torch.no_grad():
        outputs = model(**batch)

    # Convert the 3‑D tensor to a pure Python nested list
    output_list = outputs.last_hidden_state.detach().cpu().tolist()
    mask_list = batch["attention_mask"].cpu().tolist()

    return {
        "last_hidden_state": output_list,
        "attention_mask": mask_list
    }
