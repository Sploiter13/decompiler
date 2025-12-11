#!/usr/bin/env python3
import struct
import time
import base64

from flask import Flask, request, Response
import zstandard as zstd
import xxhash
import requests

app = Flask(__name__)

BYTECODE_SIGNATURE = [ord('R'), ord('S'), ord('B'), ord('1')]
BYTECODE_HASH_MULTIPLIER = 41
BYTECODE_HASH_SEED = 42

KONSTANT_API = "http://api.plusgiant5.com/konstant/decompile"
LAST_CALL = 0.0


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
            return None, "Hash mismatch (expected 0x%08X, got 0x%08X)" % (hash_value, rehash)

        decompressed_size = struct.unpack("<I", data[4:8])[0]

        dctx = zstd.ZstdDecompressor()
        decompressed = dctx.decompress(bytes(data[8:]), max_output_size=decompressed_size * 2)

        return decompressed, None
    except Exception as e:
        return None, "Exception during decompress: %s" % e


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
            timeout=30,
        )
        LAST_CALL = time.time()

        if resp.status_code != 200:
            return None, "HTTP %d: %s" % (resp.status_code, resp.text[:200])

        if "KONSTANTERROR" in resp.text:
            return None, "Konstant error: %s" % resp.text[:200]

        return resp.text, None
    except Exception as e:
        return None, "Exception during decompile: %s" % e


@app.route("/decompile", methods=["POST"])
def decompile_route():
    try:
        # body is raw base64
        b64 = request.data.decode("utf-8", errors="ignore").strip()
        if not b64:
            return Response("No body", status=400)

        try:
            encrypted = base64.b64decode(b64)
        except Exception as e:
            return Response("Base64 decode failed: %s" % e, status=400)

        print("\n[REQUEST] %d bytes after base64 decode" % len(encrypted))

        print("[1/2] Decompressing...")
        decompressed, err = decompress_bytecode(encrypted)
        if err:
            print("[ERROR] %s" % err)
            return Response("Decompression failed: %s" % err, status=400)

        print("[OK] Decompressed to %d bytes" % len(decompressed))

        print("[2/2] Decompiling...")
        source, err = decompile_bytecode(decompressed)
        if err:
            print("[ERROR] %s" % err)
            return Response("Decompilation failed: %s" % err, status=400)

        print("[OK] Decompiled, %d chars\n" % len(source))
        # return raw source (no JSON, so Lua doesn't need HttpService)
        return Response(source, status=200, mimetype="text/plain")

    except Exception as e:
        print("[FATAL] %s" % e)
        return Response("Internal error: %s" % e, status=500)


if __name__ == "__main__":
    print("\n" + "=" * 70)
    print("  Roblox Bytecode Decompiler HTTP Server")
    print("=" * 70)
    print("[✓] Listening on http://127.0.0.1:5000")
    print("[✓] POST /decompile with base64(bytecode) as body")
    print("=" * 70 + "\n")
    app.run(host="127.0.0.1", port=5000, debug=False)
