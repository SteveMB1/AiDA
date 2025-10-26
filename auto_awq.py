#!/usr/bin/env python3

from awq import AutoAWQForCausalLM                # <‑ import from **awq**
from transformers import AutoTokenizer

MODEL_ID   = "unsloth/Llama-4-Scout-17B-16E-Instruct-unsloth-bnb-4bit"
OUT_DIR    = "llm"

quant_config = {
    "zero_point":  True,     # use zero‑point (better quality)
    "q_group_size": 128,     # Mistral likes 128 groups
    "w_bit":        4,       # 4‑bit weights
    "version":     "GEMM"    # GEMM kernels (works in vLLM)
}

# 1. Load the fp16 model (low_cpu_mem_usage reduces RAM splash)
model = AutoAWQForCausalLM.from_pretrained(
    MODEL_ID,
    low_cpu_mem_usage=True,
    trust_remote_code=True,      # Mistral uses custom modules
)
tokenizer = AutoTokenizer.from_pretrained(
    MODEL_ID,
    trust_remote_code=True,
)

# 2. Quantise – uses 128 random calibration samples from the tokenizer
model.quantize(
    tokenizer,
    quant_config=quant_config,
    max_calib_samples=64,
    n_parallel_calib_samples=4,
)

# 3. Save the quantised weights + tokenizer
model.save_quantized(OUT_DIR)
tokenizer.save_pretrained(OUT_DIR)

print(f"✓ Quantised model saved to →  {OUT_DIR!r}")

