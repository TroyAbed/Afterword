#!/usr/bin/env python3
"""TCP proxy: forward ports on this Pi to the Mac Studio, re-resolving the
Studio's mDNS hostname on every new connection so clients can point at this
Pi's stable address even when the Studio's DHCP-assigned IP changes.

  11434 -> Studio:11434   (Ollama)
   8756 -> Studio:8756    (Afterword)
"""
import asyncio
import socket
import sys

TARGET_HOST = "Mac-Studio-von-Maurus.local"
FORWARDS = {          # this Pi's listen port -> Studio port
    11434: 11434,
    8756: 8756,
}


async def pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError):
        pass
    finally:
        writer.close()


def make_handler(target_port: int):
    async def handle_client(client_reader, client_writer):
        peer = client_writer.get_extra_info("peername")
        try:
            target_ip = socket.gethostbyname(TARGET_HOST)
        except socket.gaierror as e:
            print(f"[proxy:{target_port}] DNS resolve failed for {peer}: {e}", flush=True)
            client_writer.close()
            return
        try:
            target_reader, target_writer = await asyncio.open_connection(target_ip, target_port)
        except OSError as e:
            print(f"[proxy:{target_port}] connect {target_ip}:{target_port} failed ({peer}): {e}", flush=True)
            client_writer.close()
            return
        print(f"[proxy:{target_port}] {peer} -> {target_ip}:{target_port}", flush=True)
        await asyncio.gather(
            pipe(client_reader, target_writer),
            pipe(target_reader, client_writer),
        )
    return handle_client


async def main():
    servers = []
    for listen_port, target_port in FORWARDS.items():
        servers.append(await asyncio.start_server(
            make_handler(target_port), "0.0.0.0", listen_port))
        print(f"[proxy] listening 0.0.0.0:{listen_port} -> {TARGET_HOST}:{target_port}", flush=True)
    await asyncio.gather(*(s.serve_forever() for s in servers))


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
