import asyncio
import contextlib
import importlib
import multiprocessing
import os
import signal
import socket
from pathlib import Path

import uvicorn
from starlette.requests import Request

from agent.database import create_indexes
from database import create_indexes_main
from dependencies import router, read_current_user
from notifications import periodic_alert

# Set Hugging Face to offline mode
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_DATASETS_OFFLINE"] = "1"
os.environ["HF_HUB_OFFLINE"] = "1"

# Disable vLLM usage data tracking
os.environ["VLLM_DO_NOT_TRACK"] = "1"
os.environ["DO_NOT_TRACK"] = "1"
os.environ["VLLM_NO_USAGE_STATS"] = "1"

from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import RedirectResponse, FileResponse
from fastapi import FastAPI, HTTPException

import embeddings
import tools
import main_agent


async def _bootstrap_once():
    await create_indexes()
    await create_indexes_main()


app = FastAPI()
app.include_router(router)
current_dir = Path(__file__).parent

for path in current_dir.glob("*.py"):
    if path.name in ("main.py", "generate_jwt_secret.py", "dependencies.py"):
        continue

    module_name = path.stem
    module = importlib.import_module(module_name)
    if hasattr(module, "router"):
        print(f"Importing API Routes Inside of: {path.name}")
        app.include_router(module.router)


def _bg_process_entry() -> None:
    """Infinite asyncio loop that hosts main_agent.start_background_tasks()."""
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

    async def runner() -> None:
        task = asyncio.create_task(start_background_tasks())

        # graceful shutdown on SIGINT / SIGTERM
        stop = asyncio.Future()
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, stop.set_result, None)

        try:
            await stop  # blocks until a signal arrives
        finally:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task

    loop.run_until_complete(runner())
    loop.close()


async def start_background_tasks():
    return await asyncio.gather(
        periodic_alert(),
        main_agent.fetch_runner(),
        main_agent.env_loop()
    )


def main():
    # 1️⃣ cluster-wide async init
    asyncio.run(_bootstrap_once())

    # 2️⃣ spawn a single sidecar
    multiprocessing.set_start_method("spawn", force=True)
    bg_proc = multiprocessing.Process(
        target=_bg_process_entry,
        name="bg-tasks-proc",
        daemon=True,
    )
    bg_proc.start()

    # 3️⃣ forward termination signals
    def _forward(sig, frame):
        if bg_proc.is_alive():
            bg_proc.terminate()

    for s in (signal.SIGINT, signal.SIGTERM):
        signal.signal(s, _forward)

    # 4️⃣ launch N async workers
    try:
        uvicorn.run(
            "main:app",  # import string → workers > 1 allowed
            host="0.0.0.0",
            port=8000,
            loop="uvloop",
            workers=os.cpu_count(),
        )
    finally:
        if bg_proc.is_alive():
            bg_proc.join(timeout=5)


# Set up CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
    max_age=3600,
)


@app.get("/")
async def root_redirect():
    return RedirectResponse(url="/app")


@app.get("/healthz/")
async def health_check():
    return {"success": True}


@app.get("/app/{file_path:path}")
async def serve_app(file_path: str):
    full_path = os.path.join("app", file_path)

    if os.path.isdir(full_path):
        full_path = os.path.join(full_path, "index.html")

    if not os.path.exists(full_path) or not os.path.isfile(full_path):
        raise HTTPException(status_code=404, detail="File not found")

    return FileResponse(full_path)


@app.get("/import-codebase/")
async def import_codebase(request: Request):
    await read_current_user(request.headers.get("Authorization"))

    await embeddings.import_embeddings(
        tools.read_code_from_repo(repo_name="CreativeRadicals/infrastructure_as_code.git", branch="devops",
                                  directory="infrastructure_as_code"), "internal_codebase", "IMPORT_CODE")

    # await embeddings.import_embeddings(tools.read_code_from_repo(repo_name="aws/aws-sdk-java-v2.git",
    #                                                              branch="master",
    #                                                              directory="aws-sdk-java-v2"),
    #                                    "external_codebase", "IMPORT_CODE")


if __name__ == "__main__":
    try:
        main()
    finally:
        hostname = socket.gethostname()
