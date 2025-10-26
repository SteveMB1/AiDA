#!/bin/bash
set -e  # fail fast on errors (optional but usually helpful)

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
