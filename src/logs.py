import logging
import sys

logging.basicConfig(
    level=logging.INFO,  # DEBUG if you want **everything**
    format="%(asctime)s  %(levelname)-8s  %(name)s: %(message)s",
    handlers=[
        logging.FileHandler("service.log", encoding="utf-8"),
        logging.StreamHandler(sys.stderr)  # keep stderr for kubectl logs etc.
    ],
    force=True  # clobber any previous config
)
