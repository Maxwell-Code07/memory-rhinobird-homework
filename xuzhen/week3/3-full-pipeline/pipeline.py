#!/usr/bin/env python3
"""Configurable build -> run -> plugin install -> soak pipeline."""

import argparse
import subprocess
import sys
import time
from pathlib import Path


def run(command: list[str], check: bool = True) -> subprocess.CompletedProcess:
    print("$", " ".join(command), flush=True)
    return subprocess.run(command, check=check)


def mapping(value: str, option: str) -> tuple[str, str]:
    if "=" not in value:
        raise argparse.ArgumentTypeError(f"{option} must use SOURCE=DESTINATION")
    source, destination = value.split("=", 1)
    if not source or not destination:
        raise argparse.ArgumentTypeError(f"{option} must use SOURCE=DESTINATION")
    return source, destination


def main() -> int:
    p = argparse.ArgumentParser(description="Run the Hermes Docker + memory soak pipeline")
    p.add_argument("--version", default="0.20.6")
    p.add_argument("--image", default=None)
    p.add_argument("--plugin-command", required=True, help="command executed inside container to install/configure plugin")
    p.add_argument("--gateway-command", default="hermes gateway", help="gateway command executed inside container")
    p.add_argument("--soak-command", required=True, help="soak command executed inside container")
    p.add_argument("--env-file", type=Path, default=None, help="shared .env file passed to Hermes and Gateway")
    p.add_argument("--copy", action="append", type=lambda value: mapping(value, "--copy"), default=[],
                   metavar="SOURCE=DESTINATION", help="copy a local file into the container before setup")
    p.add_argument("--copy-out", action="append", type=lambda value: mapping(value, "--copy-out"), default=[],
                   metavar="SOURCE=DESTINATION", help="copy a container result path to the host before cleanup")
    p.add_argument("--gateway-wait", type=float, default=5.0, help="seconds to wait after starting Gateway")
    p.add_argument("--keep", action="store_true", help="keep container after completion")
    args = p.parse_args()
    image = args.image or f"hermes:{args.version}"
    repo = Path(__file__).resolve().parents[2]
    dockerfile = repo / "week2" / "Dockerfile"
    context = repo / "week2"
    env_file = args.env_file or Path(__file__).resolve().parents[1] / ".env"
    container = f"hermes-pipeline-{int(time.time())}"
    if args.gateway_wait < 0:
        p.error("--gateway-wait must be >= 0")
    run(["docker", "build", "--progress=plain", "--build-arg", f"HERMES_VERSION={args.version}", "-f", str(dockerfile), "-t", image, str(context)])
    try:
        docker_run = ["docker", "run", "--name", container, "-dit"]
        if env_file.is_file():
            docker_run += ["--env-file", str(env_file)]
        run(docker_run + ["--entrypoint", "sh", image, "-lc", "sleep infinity"])
        run(["docker", "exec", container, "sh", "-lc", args.plugin_command])
        for source, destination in args.copy:
            source_path = Path(source)
            if not source_path.is_file():
                raise FileNotFoundError(f"--copy source does not exist: {source_path}")
            run(["docker", "cp", str(source_path), f"{container}:{destination}"])
        run(["docker", "exec", "-d", container, "sh", "-lc", args.gateway_command])
        time.sleep(args.gateway_wait)
        result = run(["docker", "exec", container, "sh", "-lc", args.soak_command], check=False)
        print(f"pipeline status: {'PASS' if result.returncode == 0 else 'FAIL'}")
        for source, destination in args.copy_out:
            destination_path = Path(destination)
            destination_path.parent.mkdir(parents=True, exist_ok=True)
            run(["docker", "cp", f"{container}:{source}", str(destination_path)], check=False)
        return result.returncode
    finally:
        if not args.keep:
            run(["docker", "rm", "-f", container], check=False)


if __name__ == "__main__":
    sys.exit(main())
