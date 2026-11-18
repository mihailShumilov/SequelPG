#!/usr/bin/env python3
"""Fails if docker-compose.yml ports drift from test-env.json."""
import json, pathlib, re, sys

root = pathlib.Path(__file__).resolve().parent.parent
env = json.loads((root / "test-env.json").read_text())
compose = (root / "docker-compose.yml").read_text()
errors = []
for name, server in env["servers"].items():
    if f'"127.0.0.1:{server["port"]}:5432"' not in compose:
        errors.append(f"{name}: port {server['port']} not mapped in docker-compose.yml")
    if f"image: postgres:{server['major']}" not in compose:
        errors.append(f"{name}: image postgres:{server['major']} missing")
if f'"127.0.0.1:{env["ssh"]["port"]}:22"' not in compose:
    errors.append("sshd port mismatch")
if errors:
    print("\n".join(errors)); sys.exit(1)
print("test-env.json and docker-compose.yml agree.")
