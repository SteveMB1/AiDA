#!/bin/bash
set -e  # fail fast on errors (optional but usually helpful)

mkdir -p ~/.ssh/
cp -a ai-diagnostics-user.pem ~/.ssh/
chmod 600 -R ~/.ssh

if [ "${AUTORUN}" = "true" ]; then
  source config.sh
  # use exec here so Python becomes PID 1
  exec python3 main.py
else
  echo "Autorun is disabled. Skipping Python execution. Tailing /dev/null"
  touch log
  # again, exec so tail runs as PID 1
  exec tail -f log
fi
