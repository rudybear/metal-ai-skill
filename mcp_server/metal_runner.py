"""
Async subprocess wrapper for Metal CLI tools.

Runs xctrace, xcrun metal, and other commands via asyncio.create_subprocess_exec.
Returns structured results with ok/output/error/data/exit_code fields.
All logging goes to stderr (stdout is sacred for MCP JSON-RPC).
"""

import asyncio
import json
import sys
from typing import Any


async def run_cmd(
    args: list[str],
    timeout: int = 60,
    env: dict[str, str] | None = None,
    cwd: str | None = None,
) -> dict[str, Any]:
    """Run a command and return a structured result dict.

    Args:
        args: Command and arguments (e.g., ["xcrun", "xctrace", "version"]).
        timeout: Timeout in seconds (default 60).
        env: Optional environment variables to merge with current env.
        cwd: Optional working directory.

    Returns:
        {ok: bool, output: str, error: str, data: Any, exit_code: int}
    """
    import os

    merged_env = None
    if env:
        merged_env = {**os.environ, **env}

    print(f"[metal-tools] Running: {' '.join(args)}", file=sys.stderr)

    try:
        proc = await asyncio.create_subprocess_exec(
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=merged_env,
            cwd=cwd,
        )
        stdout, stderr = await asyncio.wait_for(
            proc.communicate(), timeout=timeout
        )
    except asyncio.TimeoutError:
        try:
            proc.kill()
            await proc.wait()
        except ProcessLookupError:
            pass
        return {
            "ok": False,
            "output": "",
            "error": f"Command timed out after {timeout}s: {' '.join(args)}",
            "data": None,
            "exit_code": -1,
        }
    except FileNotFoundError:
        return {
            "ok": False,
            "output": "",
            "error": f"Command not found: {args[0]}",
            "data": None,
            "exit_code": -1,
        }
    except Exception as e:
        return {
            "ok": False,
            "output": "",
            "error": str(e),
            "data": None,
            "exit_code": -1,
        }

    out_text = stdout.decode("utf-8", errors="replace").strip()
    err_text = stderr.decode("utf-8", errors="replace").strip()
    ok = proc.returncode == 0

    # Try JSON parsing if output looks like JSON
    data = None
    if out_text:
        for flag in ("--json", "--format json", "-format json"):
            if flag in " ".join(args):
                try:
                    data = json.loads(out_text)
                except (json.JSONDecodeError, ValueError):
                    pass
                break

    return {
        "ok": ok,
        "output": out_text,
        "error": err_text,
        "data": data,
        "exit_code": proc.returncode,
    }


def format_result(result: dict[str, Any]) -> str:
    """Format a run_cmd result dict into a human-readable string."""
    parts = []

    if result.get("ok"):
        parts.append("OK")
    else:
        parts.append(f"FAILED (exit {result.get('exit_code', '?')})")

    if result.get("output"):
        parts.append(result["output"])

    if result.get("error"):
        parts.append(f"stderr: {result['error']}")

    if result.get("data") is not None:
        parts.append(f"data: {json.dumps(result['data'], indent=2)}")

    return "\n".join(parts)
