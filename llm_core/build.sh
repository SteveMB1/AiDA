#!/bin/bash
set -e

/usr/local/bin/aws ecr get-login-password --region us-east-2 | docker login --username AWS --password-stdin 060767352619.dkr.ecr.us-east-2.amazonaws.com

docker build \
    --build-arg BASE_IMAGE="${BASE_IMAGE}:${BASE_IMG_VERSION}" \
    . --tag 060767352619.dkr.ecr.us-east-2.amazonaws.com/internalinsights/llmcore:latest

docker push 060767352619.dkr.ecr.us-east-2.amazonaws.com/internalinsights/llmcore:latest