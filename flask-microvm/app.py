"""Minimal Flask app to run inside a Lambda MicroVM.

Serves two endpoints so we can prove (a) the VM answers over its HTTPS
endpoint and (b) in-VM state survives a suspend -> resume cycle.
"""
import os
import time

from flask import Flask, jsonify

app = Flask(__name__)

# In-memory state. If this survives a suspend/resume, the Firecracker
# snapshot restored process memory (the whole point of MicroVMs).
BOOT_TIME = time.time()
COUNTER = {"hits": 0}


@app.get("/")
def index():
    COUNTER["hits"] += 1
    return jsonify(
        message="hello from inside a Lambda MicroVM",
        hits=COUNTER["hits"],
        uptime_seconds=round(time.time() - BOOT_TIME, 1),
        hostname=os.uname().nodename,
    )


@app.get("/health")
def health():
    return jsonify(status="ok")


if __name__ == "__main__":
    # 0.0.0.0 so the MicroVM ingress connector can reach it.
    app.run(host="0.0.0.0", port=5000)
