export core_endpoint="http://llmcore:8000"
export elasticsearch_host="http://elasticsearch-1:9200"
export PREVIOUS_SUMMARY_SEARCH_PROMPT="Rephrase the previous questions into a single question that is concise and still include nouns and file names if the latest question is still on the same topic. Otherwise, just enhance the latest question. If asked about a variable in the infrastructure as code these values are specified inside of /infrastructure_as_code/ansible/vars/*.yaml. If this question is part of your general knowledge and not something to do with a codebase, reply only with the word 'skip'"
export ANSIBLE_SSH_RETRIES=3
export llm_platform="openai"
export OPENAI_API_KEY=""
export OPENAI_MODEL="gpt-4.1-mini"
