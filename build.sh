#!/bin/bash
set -e

/usr/local/bin/aws ecr get-login-password --region us-east-2 | docker login --username AWS --password-stdin <AWS ACCOUNT ID>.dkr.ecr.us-east-2.amazonaws.com

# Flutter Build
flutter config --no-analytics
flutter config --no-cli-animations
cd diag_ui
flutter build web --base-href /app/
mkdir ../src/app
cp -aR build/web/* ../src/app

# Docker Build
cd ../

docker build \
    --build-arg BASE_IMAGE="${BASE_IMAGE}:${BASE_IMG_VERSION}" \
    . --tag <AWS ACCOUNT ID>dkr.ecr.us-east-2.amazonaws.com/internalinsights/aida:latest

docker push <AWS ACCOUNT ID>dkr.ecr.us-east-2.amazonaws.com/internalinsights/aida:latest
