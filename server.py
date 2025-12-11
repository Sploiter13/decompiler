#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import struct
import time
import base64
import sys
import threading
import zstandard as zstd
import xxhash
import requests
from flask import Flask, request, Response
import os

# Keep console open on Windows
if sys.platform.startswith('win'):
    import ctypes
    kernel32 = ctypes.windll.kernel32
    kernel32.AllocConsole()
    console_out = open('CONOUT$', 'w', encoding='utf-8')
    console_err = open('CONOUT$', 'w', encoding='utf-8')
    sys.stdout = console_out
    sys.stderr = console_err

app = Flask(__name__)
server_running = True

BYTECODE_SIGNATURE = [ord('R'), ord('S'), ord('B'), ord('1')]
BYTECODE_HASH_MULTIPLIER = 41
BYTECODE_HASH_SEED = 42
KONSTANT_API = "http://api.plusgiant5.com/konstant/decompile"
LAST_CALL = 0.0

log_lock = threading.Lock()

def log(msg):
    with log_lock:
        timestamp = time.strftime("%H:%M:%S")
        log_entry = f"[{timestamp}] {msg}"
        print(log_entry)

def decompress_bytecode(compressed_data):
    try:
        if len(compressed_data) < 8:
            return None, "File too small"

        data = bytearray(compressed_data)
        header_buffer = bytearray(4)

        for i in range(4):
            decrypted = data[i] ^ BYTECODE_SIGNATURE[i]
            header_buffer[i] = (decrypted - (i * BYTECODE_HASH_MULTIPLIER)) & 0xFF

        for i in range(len(data)):
            xor_value = (header_buffer[i % 4] + (i * BYTECODE_HASH_MULTIPLIER)) & 0xFF
            data[i] ^= xor_value

        hash_value = struct.unpack("<I", header_buffer)[0]
        rehash = xxhash.xxh32(bytes(data), seed=BYTECODE_HASH_SEED).intdigest()

        if rehash != hash_value:
            return None, "Hash mismatch"

        decompressed_size = struct.unpack("<I", data[4:8])[0]
        dctx = zstd.ZstdDecompressor()
        decompressed = dctx.decompress(bytes(data[8:]), max_output_size=decompressed_size * 2)

        return decompressed, None

    except Exception as e:
        return None, f"Decompress error: {e}"

def decompile_bytecode(bytecode):
    global LAST_CALL

    try:
        now = time.time()
        elapsed = now - LAST_CALL
        if elapsed < 0.5:
            time.sleep(0.5 - elapsed)

        resp = requests.post(
            KONSTANT_API,
            data=bytecode,
            headers={"Content-Type": "text/plain"},
            timeout=30
        )

        LAST_CALL = time.time()

        if resp.status_code != 200:
            return None, f"HTTP {resp.status_code}"

        if "KONSTANTERROR" in resp.text:
            return None, "Konstant error"

        return resp.text, None

    except Exception as e:
        return None, f"Decompile error: {e}"

@app.route("/decompile", methods=["POST"])
def decompile_route():
    global server_running

    if not server_running:
        return Response("Server shutting down", status=503)

    try:
        b64 = request.data.decode("utf-8", errors="ignore").strip()
        if not b64:
            return Response("No body", status=400)

        encrypted = base64.b64decode(b64)
        log(f"[REQUEST] {len(encrypted)} bytes received")
        log("[1/2] Decompressing...")

        decompressed, err = decompress_bytecode(encrypted)
        if err:
            log(f"[ERROR] {err}")
            return Response(f"Decompression failed: {err}", status=400)

        log(f"[OK] Decompressed {len(decompressed)} bytes")
        log("[2/2] Decompiling...")

        source, err = decompile_bytecode(decompressed)
        if err:
            log(f"[ERROR] {err}")
            return Response(f"Decompilation failed: {err}", status=400)

        log(f"[OK] Decompiled {len(source)} chars")
        return Response(source, status=200, mimetype="text/plain")

    except Exception as e:
        log(f"[FATAL] {e}")
        return Response(f"Internal error: {e}", status=500)

def main():
    global server_running

    log("=" * 80)
    log("Listening at: http://127.0.0.1:5000/decompile")
    log("=" * 80)

    try:
        from werkzeug.serving import run_simple
        run_simple('127.0.0.1', 5000, app, threaded=True)

    except KeyboardInterrupt:
        log("Ctrl+C received")

    except Exception as e:
        log(f"Error: {e}")

    finally:
        server_running = False
        log("Server shutdown complete")

        if sys.platform.startswith('win'):
            input("\nPress Enter to close...")

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"FATAL: {e}")
        input("Press Enter to close...")
