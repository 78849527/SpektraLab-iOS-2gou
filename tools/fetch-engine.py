#!/usr/bin/env python3
"""Fetch the upstream engine's tree through the GitHub API.

    python3 tools/fetch-engine.py <upstream-repo> <commit> <destination>

Why not `git clone` or the tarball: **neither of them delivers
`engine/resources`.** The tree API says the files are in the commit -- 33
blobs under `engine/resources`, the 9.4 MB `spektrafilm_constants.bin` among
them -- and a full clone, a shallow clone, a partial clone and the tarball all
produced a tree with an `engine` directory and no `resources` in it. A tree
that four different ways of fetching agree on, and that disagrees with the
tree API, is a GitHub-side behaviour nobody's git flags are going to fix.

So this asks for the tree and asks for each file, and it checks what came
back. The tree API is the authority on what the commit contains, and the
blob API is the authority on the bytes.

The API's own limits are respected: a thousand requests an hour, and a
 hundred megabytes of content an hour. This makes a few hundred requests, so
 it fits in both with room to spare.

Anonymous access is enough for a public repository, so no token is needed;
`GITHUB_TOKEN` is used when it is set, because it raises the limit.
"""

from __future__ import annotations

import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

API = "https://api.github.com"

# The directories the app needs. Everything else in the upstream engine -- the
# tests, the host CLI, the tools -- is either desktop-shaped or not needed to
# build the app.
WANTED = (
    "engine/src",
    "engine/include",
    "engine/third_party/metal-cpp",
    "engine/resources",
    "engine/resources_product",
)

# The upstream's `engine/third_party` also has `stb`, which the app does not
# compile; skipping it saves a few megabytes of requests.
SKIP_PREFIXES = ("engine/third_party/stb",)


def api(url: str, token: str, tries: int = 4):
    headers = {"User-Agent": "spektralab-ios-fetch"}
    if token:
        headers["Authorization"] = f"token {token}"
    for attempt in range(tries):
        request = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            # 403 is the rate limit; 404 is a file that is not there; both
            # are worth one more try, because the network here is a proxy
            # that drops connections.
            if error.code not in (403, 404, 502, 503, 504) or attempt == tries - 1:
                raise
            time.sleep(2 + attempt * 3)
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            if attempt == tries - 1:
                raise
            time.sleep(2 + attempt * 3)
    raise RuntimeError("unreachable")


def walk(tree: list[dict]) -> list[str]:
    """The blob paths in a flat tree."""
    return [entry["path"] for entry in tree if entry["type"] == "blob"]


def fetch_blob(repo: str, sha: str, token: str) -> bytes:
    """One blob's bytes, by its sha."""
    headers = {"User-Agent": "spektralab-ios-fetch", "Accept": "application/vnd.github.raw"}
    if token:
        headers["Authorization"] = f"token {token}"
    url = f"{API}/repos/{repo}/git/blobs/{sha}"
    for attempt in range(4):
        request = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=300) as response:
                data = response.read()
            # The raw media type gives the bytes; the JSON one gives a
            # base64 blob. Which one comes back depends on the accept
            # header and on the blob's size, so both are handled.
            if data[:1] in (b"{", b"[") and b"encoding" in data[:200]:
                parsed = json.loads(data)
                if parsed.get("encoding") == "base64":
                    return base64.b64decode(parsed["content"])
                return parsed.get("content", "").encode("utf-8")
            return data
        except urllib.error.HTTPError as error:
            if attempt == 3:
                raise
            time.sleep(2 + attempt * 3)
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            if attempt == 3:
                raise
            time.sleep(2 + attempt * 3)
    raise RuntimeError("unreachable")


def main() -> None:
    if len(sys.argv) < 4:
        print("usage: fetch-engine.py <repo> <commit> <destination>")
        sys.exit(2)
    repo = sys.argv[1]
    commit = sys.argv[2]
    destination = Path(sys.argv[3])
    token = os.environ.get("GITHUB_TOKEN", "").strip()

    print(f"fetching {repo}@{commit[:12]} -> {destination}")

    # 1) The tree, recursively. This is the authority on what the commit
    #    contains.
    tree = api(f"{API}/repos/{repo}/git/trees/{commit}?recursive=1", token)
    if tree.get("truncated"):
        raise SystemExit("the tree is truncated; the upstream repository is "
                         "too large for one tree request")
    blobs = walk(tree["tree"])
    wanted = [p for p in blobs
              if any(p.startswith(prefix) for prefix in WANTED)
              and not any(p.startswith(prefix) for prefix in SKIP_PREFIXES)]
    print(f"  the tree has {len(blobs)} files; {len(wanted)} of them are the engine")

    # 2) The blobs, by sha. The tree gives the sha for each path, so the
    #    blob is fetched by identity rather than by path.
    shas = {entry["path"]: entry["sha"]
            for entry in tree["tree"]
            if entry["type"] == "blob"}

    destination.mkdir(parents=True, exist_ok=True)
    written = 0
    total = 0
    for index, path in enumerate(wanted, 1):
        target = destination / path
        target.parent.mkdir(parents=True, exist_ok=True)
        data = fetch_blob(repo, shas[path], token)
        target.write_bytes(data)
        written += 1
        total += len(data)
        if index % 25 == 0 or index == len(wanted):
            print(f"  {index}/{len(wanted)} files, {total / 1048576:.1f} MB")

    # 3) The check. The build fails later, and further away, if the engine is
    #    incomplete; this says what is missing while it is still cheap to fix.
    required = [
        "engine/include/spektrafilm/spk_engine.h",
        "engine/resources/spektrafilm_constants.bin",
        "engine/resources/print_luts.json",
        "engine/src/gpu/metal_gpu.cpp",
        "engine/src/pipeline/engine.cpp",
        "engine/src/shaders/nodes.metal",
    ]
    missing = [p for p in required if not (destination / p).exists()]
    if missing:
        for path in missing:
            print(f"::error::missing {path}")
        raise SystemExit("the engine is incomplete")
    if not (destination / "engine/resources/profiles").is_dir():
        raise SystemExit("the engine has no stock profiles")

    profiles = len(list((destination / "engine/resources/profiles").glob("*.json")))
    print(f"the engine is in place: {written} files, {total / 1048576:.1f} MB, "
          f"{profiles} stock profiles")


if __name__ == "__main__":
    main()
