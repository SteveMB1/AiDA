#export MODEL_NAME="unsloth/Llama-3.3-70B-Instruct"
#export EMBEDDING_MODEL="intfloat/e5-large-v2"

export MODEL_NAME="/models/llm"
export EMBEDDING_MODEL="/models/embedding"
export PREVIOUS_SUMMARY_SEARCH_PROMPT="Rephrase the previous questions into a single question that is concise and still include nouns and file names if the latest question is still on the same topic. Otherwise, just enhance the latest question. If asked about a variable in the infrastructure as code these values are specified inside of /infrastructure_as_code/ansible/vars/*.yaml. If this question is part of your general knowledge and not something to do with a codebase, reply only with the word 'skip'"
