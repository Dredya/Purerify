#!/usr/bin/env bash
cd "$(dirname "$0")"
python -m uvicorn main:app --host 0.0.0.0 --port 8443 --ssl-keyfile key.pem --ssl-certfile cert.pem --reload