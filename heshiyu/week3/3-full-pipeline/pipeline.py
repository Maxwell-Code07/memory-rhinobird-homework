#!/usr/bin/env python3
"""Run the Week3 Hermes + memory-tencentdb Docker pipeline.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Iterable, Sequence


SCRIPT_DIR = Path(__file__).resolve().parent
VERSION_RE = re.compile(r"^0\.\d+\.\d+$")

for stream in (sys.stdout, sys.stderr):
    reconfigure = getattr(stream, "reconfigure", None)
    if reconfigure is not None:
        reconfigure(encoding="utf-8", errors="replace")


def load_dotenv(path: Path) -> None:
    """Load simple KEY=VALUE entries without replacing exported variables."""
    if not path.is_file():
        return
    for raw_line in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if value[:1] == value[-1:] and value[:1] in {"'", '"'}:
            value = value[1:-1]
        if key:
            os.environ.setdefault(key, value)


def resolve_cli() -> argparse.Namespace:
    pre_parser = argparse.ArgumentParser(add_help=False)
    pre_parser.add_argument("--env-file", default=str(SCRIPT_DIR / ".env"))
    pre_args, _ = pre_parser.parse_known_args()
    load_dotenv(Path(pre_args.env_file).expanduser().resolve())

    parser = argparse.ArgumentParser(
        description="Build Hermes, install memory-tencentdb, run soak, and verify L0-L3.",
    )
    parser.add_argument("--env-file", default=pre_args.env_file, help="dotenv file (default: .env)")
    parser.add_argument("--hermes-version", default=os.getenv("HERMES_VERSION", "0.20.6"))
    parser.add_argument("--base-url", default=os.getenv("HERMES_SOAK_BASE_URL", ""))
    parser.add_argument("--model", default=os.getenv("HERMES_SOAK_MODEL", ""))
    parser.add_argument("--api-key", default=os.getenv("HERMES_SOAK_API_KEY", ""))
    parser.add_argument("--memory-base-url", default=os.getenv("TDAI_LLM_BASE_URL", ""))
    parser.add_argument("--memory-model", default=os.getenv("TDAI_LLM_MODEL", ""))
    parser.add_argument("--memory-api-key", default=os.getenv("TDAI_LLM_API_KEY", ""))
    parser.add_argument(
        "--memory-package",
        default=os.getenv(
            "MEMORY_PACKAGE_SPEC",
            "@tencentdb-agent-memory/memory-tencentdb@1.0.1",
        ),
    )
    parser.add_argument("--rounds", type=int, default=int(os.getenv("SOAK_ROUNDS", "6")))
    parser.add_argument("--interval", default=os.getenv("SOAK_INTERVAL", "1s"))
    parser.add_argument("--duration", default=os.getenv("SOAK_DURATION", "15m"))
    parser.add_argument(
        "--gateway-port",
        type=int,
        default=int(os.getenv("MEMORY_GATEWAY_PORT", "8473")),
    )
    parser.add_argument("--output-dir", help="new or empty output directory")
    parser.add_argument("--keep-container", action="store_true")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="validate configuration and print the execution plan without changing state",
    )
    args = parser.parse_args()

    if not VERSION_RE.fullmatch(args.hermes_version):
        parser.error("--hermes-version must use the 0.x.x format")
    if args.rounds < 2:
        parser.error("--rounds must be at least 2 for the memory scenario")
    if not 1 <= args.gateway_port <= 65535:
        parser.error("--gateway-port must be between 1 and 65535")
    missing = [
        name
        for name, value in (
            ("HERMES_SOAK_BASE_URL/--base-url", args.base_url),
            ("HERMES_SOAK_MODEL/--model", args.model),
            ("HERMES_SOAK_API_KEY/--api-key", args.api_key),
        )
        if not value.strip()
    ]
    if missing:
        parser.error("missing required model configuration: " + ", ".join(missing))

    args.memory_base_url = args.memory_base_url or args.base_url
    args.memory_model = args.memory_model or args.model
    args.memory_api_key = args.memory_api_key or args.api_key
    return args


class Pipeline:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        self.image = f"hermes-week3:{args.hermes_version}"
        safe_version = args.hermes_version.replace(".", "-")
        self.container = f"hermes-week3-{safe_version}-{self.stamp}"
        default_output = SCRIPT_DIR / "results" / f"pipeline-{args.hermes_version}-{self.stamp}"
        self.results_dir = Path(args.output_dir).expanduser().resolve() if args.output_dir else default_output
        self.data_dir = (SCRIPT_DIR / ".runtime" / f"data-{args.hermes_version}-{self.stamp}").resolve()
        self.npm_cache_dir = (SCRIPT_DIR / ".runtime" / "npm-cache").resolve()
        self.pipeline_log = self.results_dir / "pipeline.log"
        self.snapshot_dir = self.results_dir / "memory-snapshot"
        self.log_handle = None
        self.container_started = False
        self.soak_code = 1
        self.memory_code = 1
        self.status = "fail"
        self.error_message = ""
        getuid = getattr(os, "getuid", None)
        getgid = getattr(os, "getgid", None)
        self.host_owner = (getuid(), getgid()) if getuid and getgid else None
        self.secrets = sorted(
            {args.api_key, args.memory_api_key} - {""}, key=len, reverse=True
        )
        self.environment = os.environ.copy()
        self.environment.update(
            {
                "HERMES_SOAK_BASE_URL": args.base_url,
                "HERMES_SOAK_MODEL": args.model,
                "HERMES_SOAK_API_KEY": args.api_key,
                "TDAI_LLM_BASE_URL": args.memory_base_url,
                "TDAI_LLM_MODEL": args.memory_model,
                "TDAI_LLM_API_KEY": args.memory_api_key,
                "TDAI_DATA_DIR": "/opt/data/.memory-tencentdb/memory-tdai",
                "TDAI_INSTALL_DIR": "/workspace/.memory-tencentdb/tdai-memory-openclaw-plugin",
                "TDAI_GATEWAY_HOST": "0.0.0.0",
                "TDAI_GATEWAY_PORT": "8420",
                "MEMORY_TENCENTDB_GATEWAY_HOST": "127.0.0.1",
                "MEMORY_TENCENTDB_GATEWAY_PORT": "8420",
                "MEMORY_PACKAGE_SPEC": args.memory_package,
                "HERMES_AGENT_DIR": "/opt/hermes",
                "HERMES_CONFIG_SOURCE": "/week3/config/hermes-config.yaml",
                "NPM_CONFIG_CACHE": "/opt/npm-cache",
            }
        )

    def redact(self, text: str) -> str:
        for secret in self.secrets:
            text = text.replace(secret, "[REDACTED]")
        return text

    def emit(self, text: str) -> None:
        safe_text = self.redact(text.rstrip("\r\n"))
        print(safe_text, flush=True)
        if self.log_handle is not None:
            self.log_handle.write(safe_text + "\n")
            self.log_handle.flush()

    def phase(self, message: str) -> None:
        self.emit(f"=== {message} ===")

    def prepare(self) -> None:
        if self.results_dir.exists() and any(self.results_dir.iterdir()):
            raise RuntimeError("--output-dir must be new or empty")
        self.results_dir.mkdir(parents=True, exist_ok=True)
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.npm_cache_dir.mkdir(parents=True, exist_ok=True)
        if os.name == "posix":
            # The container runs Hermes as UID 10000. These task-specific bind
            # mounts must therefore be writable without assuming the host UID.
            for directory in (self.results_dir, self.data_dir, self.npm_cache_dir):
                directory.chmod(0o777)
        self.log_handle = self.pipeline_log.open("w", encoding="utf-8", newline="\n")

    def run_command(self, command: Sequence[str], *, allow_failure: bool = False) -> int:
        self.emit("> " + shlex.join(str(part) for part in command))
        process = subprocess.Popen(
            [str(part) for part in command],
            cwd=SCRIPT_DIR,
            env=self.environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
        )
        assert process.stdout is not None
        for line in process.stdout:
            self.emit(line)
        code = process.wait()
        if code != 0 and not allow_failure:
            raise RuntimeError(f"command failed with exit code {code}: {command[0]}")
        return code

    def check_prerequisites(self) -> None:
        if shutil.which("docker") is None:
            raise RuntimeError("docker was not found in PATH")
        result = subprocess.run(
            ["docker", "info"],
            cwd=SCRIPT_DIR,
            env=self.environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
        if result.returncode != 0:
            detail = self.redact(result.stderr.strip())
            raise RuntimeError(f"Docker daemon is unavailable: {detail}")

    def docker_mount(self, source: Path, target: str, *, read_only: bool = False) -> str:
        suffix = ",readonly" if read_only else ""
        return f"type=bind,source={source.resolve()},target={target}{suffix}"

    def save_docker_stats(self, output_path: Path) -> None:
        command = ["docker", "stats", "--no-stream", "--format", "{{json .}}", self.container]
        result = subprocess.run(
            command,
            cwd=SCRIPT_DIR,
            env=self.environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
        lines = [self.redact(line) for line in result.stdout.splitlines() if line.strip()]
        json_line = next((line for line in lines if line.lstrip().startswith("{")), "")
        if result.returncode == 0 and json_line:
            try:
                payload = json.loads(json_line)
            except json.JSONDecodeError:
                payload = {"status": "unavailable", "message": json_line}
        else:
            payload = {
                "status": "unavailable",
                "docker_exit_code": result.returncode,
                "message": "\n".join(lines),
            }
        output_path.write_text(
            json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )

    def wait_for_health(self) -> dict:
        url = f"http://127.0.0.1:{self.args.gateway_port}/health"
        last_error = "no response"
        for _ in range(60):
            try:
                with urllib.request.urlopen(url, timeout=2) as response:
                    body = json.loads(response.read().decode("utf-8"))
                if body.get("status") in {"ok", "degraded"}:
                    return body
                last_error = f"unexpected status: {body.get('status')!r}"
            except (OSError, ValueError, urllib.error.URLError) as error:
                last_error = str(error)
            time.sleep(1)
        self.run_command(
            [
                "docker",
                "exec",
                self.container,
                "sh",
                "-c",
                'tail -n 100 "$HERMES_HOME/gateway.stdout.log" "$HERMES_HOME/gateway.stderr.log"',
            ],
            allow_failure=True,
        )
        raise RuntimeError(f"Memory Gateway did not become healthy: {last_error}")

    def capture_fresh_baseline(self) -> None:
        memory_dir = self.data_dir / ".memory-tencentdb" / "memory-tdai"
        baseline: dict[str, object] = {
            "captured_at": datetime.now().astimezone().isoformat(),
            "data_dir": str(memory_dir),
            "phase": "before-soak",
        }
        counts: list[int] = []
        for layer in ("conversations", "records", "scene_blocks"):
            layer_path = memory_dir / layer
            count = sum(1 for item in layer_path.rglob("*") if item.is_file()) if layer_path.is_dir() else 0
            baseline[layer] = {"exists": layer_path.is_dir(), "file_count": count}
            counts.append(count)
        persona_count = sum(1 for _ in memory_dir.rglob("persona.md")) if memory_dir.is_dir() else 0
        baseline["persona"] = {"exists": persona_count > 0, "file_count": persona_count}
        baseline["fresh"] = all(count == 0 for count in counts) and persona_count == 0
        (self.results_dir / "fresh-data-baseline.json").write_text(
            json.dumps(baseline, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        if not baseline["fresh"]:
            raise RuntimeError("memory data was not empty before soak")

    def copy_snapshot(self) -> None:
        source_root = self.data_dir / ".memory-tencentdb" / "memory-tdai"
        self.snapshot_dir.mkdir(parents=True, exist_ok=True)
        # Current releases store L2 at scene_blocks/ and L3 at persona.md.
        # profiles/ is also copied for compatibility with releases that nest
        # scene blocks below a profile directory.
        for name in (
            "conversations",
            "records",
            "scene_blocks",
            "profiles",
            "persona.md",
            ".metadata",
        ):
            source = source_root / name
            destination = self.snapshot_dir / name
            if source.is_dir():
                shutil.copytree(source, destination, dirs_exist_ok=True)
            elif source.is_file():
                shutil.copy2(source, destination)

    def write_meta(self) -> None:
        payload = {
            "status": self.status,
            "passed": self.status == "pass",
            "hermes_version": self.args.hermes_version,
            "image": self.image,
            "container": self.container,
            "soak_exit_code": self.soak_code,
            "memory_verification_exit_code": self.memory_code,
            "memory_snapshot": str(self.snapshot_dir),
            "results_dir": str(self.results_dir),
            "data_dir": str(self.data_dir),
            "completed_at": datetime.now().astimezone().isoformat(),
        }
        if self.error_message:
            payload["error"] = self.error_message
        (self.results_dir / "pipeline-meta.json").write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

    def print_plan(self) -> None:
        print("Week3 full pipeline dry run")
        print(f"  Hermes version: {self.args.hermes_version}")
        print(f"  Image:          {self.image}")
        print(f"  Gateway:        127.0.0.1:{self.args.gateway_port}")
        print(f"  Rounds:         {self.args.rounds}")
        print(f"  Interval:       {self.args.interval}")
        print(f"  Duration:       {self.args.duration}")
        print(f"  Output:         {self.results_dir}")
        print("  Steps: build -> run -> install memory -> health -> soak -> verify -> snapshot")

    def execute(self) -> int:
        if self.args.dry_run:
            self.print_plan()
            return 0

        self.prepare()
        try:
            self.check_prerequisites()
            self.phase("[1/5] Build clean Hermes image")
            self.run_command(
                [
                    "docker",
                    "build",
                    "--progress=plain",
                    "--file",
                    str(SCRIPT_DIR / "Dockerfile"),
                    "--build-arg",
                    f"HERMES_VERSION={self.args.hermes_version}",
                    "-t",
                    self.image,
                    str(SCRIPT_DIR),
                ]
            )

            self.phase("[2/5] Start persistent container")
            environment_names: Iterable[str] = (
                "HERMES_SOAK_BASE_URL",
                "HERMES_SOAK_MODEL",
                "HERMES_SOAK_API_KEY",
                "TDAI_LLM_BASE_URL",
                "TDAI_LLM_MODEL",
                "TDAI_LLM_API_KEY",
                "TDAI_DATA_DIR",
                "TDAI_INSTALL_DIR",
                "TDAI_GATEWAY_HOST",
                "TDAI_GATEWAY_PORT",
                "NPM_CONFIG_CACHE",
                "MEMORY_TENCENTDB_GATEWAY_HOST",
                "MEMORY_TENCENTDB_GATEWAY_PORT",
                "MEMORY_PACKAGE_SPEC",
                "HERMES_AGENT_DIR",
                "HERMES_CONFIG_SOURCE",
            )
            docker_run = [
                "docker",
                "run",
                "-d",
                "--name",
                self.container,
                "-p",
                f"127.0.0.1:{self.args.gateway_port}:8420",
                "--mount",
                self.docker_mount(SCRIPT_DIR, "/week3", read_only=True),
                "--mount",
                self.docker_mount(self.results_dir, "/week3-results"),
                "--mount",
                self.docker_mount(self.data_dir, "/opt/data"),
                "--mount",
                self.docker_mount(self.npm_cache_dir, "/opt/npm-cache"),
            ]
            for name in environment_names:
                docker_run.extend(("--env", name))
            docker_run.extend(
                (
                    "--entrypoint",
                    "/bin/sh",
                    self.image,
                    "-c",
                    "while true; do sleep 3600; done",
                )
            )
            self.run_command(docker_run)
            self.container_started = True

            self.phase("[3/5] Install memory Gateway + Hermes provider + config")
            self.run_command(
                [
                    "docker",
                    "exec",
                    "--user",
                    "root",
                    self.container,
                    "bash",
                    "/week3/container/install-memory.sh",
                ]
            )

            self.phase("[4/5] Start Gateway and wait for health")
            self.run_command(
                [
                    "docker",
                    "exec",
                    "-d",
                    self.container,
                    "sh",
                    "-c",
                    'cd "$TDAI_INSTALL_DIR" && exec node --import tsx/esm src/gateway/server.ts '
                    '>> "$HERMES_HOME/gateway.stdout.log" 2>> "$HERMES_HOME/gateway.stderr.log"',
                ]
            )
            health = self.wait_for_health()
            (self.results_dir / "gateway-health.json").write_text(
                json.dumps(health, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
            self.emit("Gateway health: " + json.dumps(health, ensure_ascii=False, separators=(",", ":")))

            self.phase("[5/5] Run memory-rich soak and verify L0-L3")
            self.capture_fresh_baseline()
            self.save_docker_stats(self.results_dir / "docker-stats-before.json")
            self.soak_code = self.run_command(
                [
                    "docker",
                    "exec",
                    self.container,
                    "node",
                    "/week3/hermes-standalone-soak.mjs",
                    "--hermes",
                    "hermes",
                    "--rounds",
                    str(self.args.rounds),
                    "--interval",
                    self.args.interval,
                    "--duration",
                    self.args.duration,
                    "--expected-version",
                    self.args.hermes_version,
                    "--round-timeout",
                    "180s",
                    "--scenario",
                    "/week3/scenarios/memory-soak.json",
                    "--session",
                    f"week3-memory-{self.stamp}",
                    "--output",
                    "/week3-results/soak",
                    "--round-retries",
                    "2",
                    "--memory-probe-every",
                    str(self.args.rounds),
                    "--probe-mode",
                    "gateway",
                    "--gateway-url",
                    "http://127.0.0.1:8420",
                    "--probe-wait",
                    "300s",
                    "--probe-poll",
                    "3s",
                    "--log-file",
                    "/opt/data/gateway.stderr.log",
                ],
                allow_failure=True,
            )
            self.memory_code = self.run_command(
                [
                    "docker",
                    "exec",
                    self.container,
                    "node",
                    "/week3/verify-memory.mjs",
                    "--data-dir",
                    "/opt/data/.memory-tencentdb/memory-tdai",
                    "--gateway-url",
                    "http://127.0.0.1:8420",
                    "--session-key",
                    f"week3-independent-{self.stamp}",
                    "--expect",
                    "LinXiao",
                    "--expect",
                    "Python",
                    "--expect",
                    "PowerShell",
                    "--wait",
                    "240s",
                    "--poll",
                    "3s",
                    "--output",
                    "/week3-results/memory-verification.json",
                ],
                allow_failure=True,
            )
            self.save_docker_stats(self.results_dir / "docker-stats-after.json")
            if self.soak_code == 0 and self.memory_code == 0:
                self.copy_snapshot()
                self.status = "pass"
            else:
                self.error_message = (
                    f"soak exit code={self.soak_code}; memory verification exit code={self.memory_code}"
                )
        except KeyboardInterrupt:
            self.error_message = "pipeline interrupted by user"
            self.emit("Pipeline interrupted by user")
        except Exception as error:  # noqa: BLE001 - top-level pipeline boundary
            self.error_message = self.redact(str(error))
            self.emit(f"Pipeline error: {self.error_message}")
        finally:
            if self.container_started and not self.args.keep_container:
                try:
                    if self.host_owner is not None:
                        uid, gid = self.host_owner
                        self.run_command(
                            [
                                "docker",
                                "exec",
                                "--user",
                                "root",
                                self.container,
                                "chown",
                                "-R",
                                f"{uid}:{gid}",
                                "/week3-results",
                                "/opt/data",
                                "/opt/npm-cache",
                            ],
                            allow_failure=True,
                        )
                    self.run_command(
                        ["docker", "rm", "-f", self.container], allow_failure=True
                    )
                except Exception as cleanup_error:  # noqa: BLE001
                    cleanup_message = self.redact(str(cleanup_error))
                    self.emit(f"Container cleanup warning: {cleanup_message}")
                    if not self.error_message:
                        self.error_message = cleanup_message
            elif self.container_started:
                self.emit(f"Container kept for inspection: {self.container}")
            self.write_meta()
            if self.log_handle is not None:
                self.log_handle.flush()
                self.log_handle.close()
                self.log_handle = None

        print(f"Pipeline result: {self.status.upper()}")
        print(f"Artifacts: {self.results_dir}")
        return 0 if self.status == "pass" else 1


def main() -> int:
    return Pipeline(resolve_cli()).execute()


if __name__ == "__main__":
    raise SystemExit(main())
