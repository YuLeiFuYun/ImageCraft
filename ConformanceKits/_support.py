from __future__ import annotations

import hashlib
import json
import os
import re
import signal
import subprocess
import tempfile
import time
from pathlib import Path


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_digest(root: Path) -> str:
    excluded = {
        ".build",
        ".git",
        ".swiftpm",
        ".artifacts",
        "DerivedData",
        "__pycache__",
        ".DS_Store",
    }
    hasher = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        if not path.is_file() or any(part in excluded for part in path.relative_to(root).parts):
            continue
        relative = path.relative_to(root).as_posix().encode()
        payload = path.read_bytes()
        hasher.update(len(relative).to_bytes(4, "big"))
        hasher.update(relative)
        hasher.update(len(payload).to_bytes(8, "big"))
        hasher.update(payload)
    return hasher.hexdigest()


def command_output(command: list[str], cwd: Path, env: dict[str, str]) -> str:
    return subprocess.run(
        command,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout.strip()


def source_identity(repository: Path, env: dict[str, str]) -> tuple[str, int, str]:
    identity_tool = repository / "Tools/Identity/capture_source_identity.py"
    with tempfile.TemporaryDirectory(prefix="imagecraft-conformance-identity-") as temporary:
        output = Path(temporary) / "source-identity.json"
        subprocess.run(
            ["python3", str(identity_tool), "--output", str(output)],
            cwd=repository,
            env=env,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        document = json.loads(output.read_text())
    sha256 = document.get("sourceIdentitySHA256")
    file_count = document.get("fileCount")
    identity_id = document.get("identityID")
    if not isinstance(sha256, str) or not re.fullmatch(r"[0-9a-f]{64}", sha256):
        raise ValueError("ImageCraft source identity returned an invalid SHA-256")
    if not isinstance(file_count, int) or file_count <= 0:
        raise ValueError("ImageCraft source identity returned an invalid file count")
    if identity_id != "IMAGECRAFT-SOURCE-IDENTITY-V2":
        raise ValueError(f"unexpected ImageCraft source identity: {identity_id!r}")
    return sha256, file_count, identity_id


def swift_string(value: str) -> str:
    import json

    return json.dumps(value)


def terminate_group(process: subprocess.Popen[str]) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass


def run_swift_tests(
    command: list[str],
    cwd: Path,
    env: dict[str, str],
    timeout: int,
) -> tuple[int, str, float, bool]:
    started = time.monotonic()
    process = subprocess.Popen(
        command,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    timed_out = False
    try:
        output, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        terminate_group(process)
        output, _ = process.communicate()
        output += f"\nconformance run timed out after {timeout} seconds\n"
    return (124 if timed_out else process.returncode, output, time.monotonic() - started, timed_out)


def xctest_summary(output: str) -> tuple[int, int]:
    summaries = re.findall(
        r"Executed ([0-9]+) tests, with ([0-9]+) failures",
        output,
    )
    return (
        max((int(count) for count, _ in summaries), default=-1),
        max((int(count) for _, count in summaries), default=-1),
    )
