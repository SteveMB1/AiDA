import asyncio
import logging
import os
import socket
import uuid
from typing import List, Literal

import torch
import torch.multiprocessing as mp
from fastapi import APIRouter
from fastapi.responses import StreamingResponse, PlainTextResponse
from pydantic import BaseModel, Field, validator
from transformers import AutoTokenizer
from vllm import SamplingParams
from vllm.engine.async_llm_engine import AsyncLLMEngine, AsyncEngineArgs

import database

logging.basicConfig(level=logging.DEBUG, format='%(asctime)s - %(levelname)s - %(message)s')

router = APIRouter()
hostname = socket.gethostname()

model_name = os.environ.get("MODEL_NAME")

engine = None

# Load tokenizer
tokenizer = AutoTokenizer.from_pretrained(model_name, use_cache=True, local_files_only=True)
tokenizer.pad_token = tokenizer.eos_token
tokenizer.padding_side = "left"
logging.info("Tokenizer loaded successfully.")

mp.set_start_method("spawn", force=True)


def load_model():
    global engine
    logging.info(f"🔥 Loading model with vLLM...")
    try:
        # Check if CUDA is available
        if torch.cuda.is_available():
            num_gpus = torch.cuda.device_count()  # Get GPU count
            logging.info(
                f"🚀 Detected {num_gpus} GPUs. Distributing model accordingly... {[torch.cuda.get_device_name(i) for i in range(num_gpus)]}")

        else:
            num_gpus = 1

        engine_args = AsyncEngineArgs(
            model=model_name,
            tensor_parallel_size=num_gpus,
            trust_remote_code=False,  # Prevents internet access for model code
            quantization="awq",
            override_generation_config={"attn_temperature_tuning": True},
            disable_custom_all_reduce=True,
            kv_cache_dtype="fp8",  # halves cache size
            calculate_kv_scales=True  # tiny accuracy boost
        )

        # Initialize the async LLM engine
        engine = AsyncLLMEngine.from_engine_args(engine_args)

        logging.info(f"✅ vLLM Model Loaded Successfully in Offline Mode")

    except Exception as e:
        logging.error(f"❌ Error loading model: {e}")
        raise


async def generate_core(chat_history: List[dict], job_uuid: str):
    async_job_removed = False
    try:
        # Prepare the prompt
        formatted_prompt = tokenizer.apply_chat_template(
            chat_history, add_generation_prompt=True, tokenize=False
        )

        sampling_params = SamplingParams(
            stop_token_ids=[tokenizer.eos_token_id],
            max_tokens=50000,
        )

        # Insert data into index with retry
        await database.insert_await_async(
            index="async_generation_jobs",
            body={"hostname": hostname, "uuid": job_uuid}
        )

        previous_output = ""

        async for request_output in engine.generate(formatted_prompt, sampling_params, job_uuid):
            for output in request_output.outputs:
                new_text = output.text
                if new_text.startswith(previous_output):
                    new_tokens = new_text[len(previous_output):]
                else:
                    new_tokens = new_text
                previous_output = new_text

                if new_tokens:
                    yield new_tokens

    except asyncio.CancelledError:
        # Cleanup on cancellation
        logging.warning(f"Task cancelled, cleaning up job {job_uuid}")
        if not async_job_removed:
            database.delete_job_from_async_generation_jobs(job_uuid)
            async_job_removed = True
        raise

    except Exception as e:
        # Cleanup on general exception
        logging.error(f"Error in generate_core: {e}")
        yield f"An error occurred: {e}"
        if not async_job_removed:
            database.delete_job_from_async_generation_jobs(job_uuid)
            async_job_removed = True
        raise

    finally:
        if not async_job_removed:
            database.delete_job_from_async_generation_jobs(job_uuid)


class ChatMessage(BaseModel):
    role: Literal["system", "user", "assistant"] = Field(..., description="Who is sending this message")
    content: str = Field(..., description="The text of the message")

    @validator("content", pre=True)
    def force_str(cls, v):
        return str(v)


class ChatTemplateRequest(BaseModel):
    messages: List[ChatMessage] = Field(..., description="The conversation history to format")


@router.post("/llm")
async def generate_llm(req: ChatTemplateRequest):
    try:
        messages = [m.model_dump() for m in req.messages]
        job_uuid = str(uuid.uuid4())

        # Ensure generate_core is an async generator
        async def stream_generator():
            async for chunk in generate_core(chat_history=messages, job_uuid=job_uuid):
                yield chunk

        return StreamingResponse(stream_generator(), media_type="text/plain")

    except Exception as e:
        # Return the exact error as plain text
        return PlainTextResponse(content=f"Error: {str(e)}", status_code=500)
