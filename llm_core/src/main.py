import os

from fastapi import FastAPI

# Set Hugging Face to offline mode
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_DATASETS_OFFLINE"] = "1"
os.environ["HF_HUB_OFFLINE"] = "1"

# Disable vLLM usage data tracking
os.environ["VLLM_DO_NOT_TRACK"] = "1"
os.environ["DO_NOT_TRACK"] = "1"
os.environ["VLLM_NO_USAGE_STATS"] = "1"
os.environ["VLLM_LOGGING_LEVEL"] = "DEBUG"

import threading
from fastapi.middleware.cors import CORSMiddleware

from routes import load_model
from embeddings import *

logging.basicConfig(level=logging.DEBUG, format='%(asctime)s - %(levelname)s - %(message)s')

app = FastAPI()

# Set up CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
    max_age=3600,
)


@app.get("/healthz/")
async def health_check():
    return {"success": True}


# Include your API router
app.include_router(router)


def run_uvicorn():
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)


if __name__ == "__main__":
    try:
        # Load your model
        load_model()

        # Start the Uvicorn server in another thread
        uvicorn_thread = threading.Thread(target=run_uvicorn, daemon=True)
        uvicorn_thread.start()

        logging.info("Uvicorn is running in a separate thread.")

        # Optionally, wait for the Uvicorn thread to finish
        uvicorn_thread.join()
    except Exception as e:
        logging.error(e)
