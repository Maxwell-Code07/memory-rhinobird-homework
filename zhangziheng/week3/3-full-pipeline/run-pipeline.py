#!/usr/bin/env python3
"""Cross-platform Week 3 Dockerfile + Hermes soak pipeline.

Loads configuration from .env in the current directory first, then from this
script's directory. Secrets are written only to the temporary Hermes home
volume and are scrubbed in the final cleanup path.
"""

from __future__ import annotations

import argparse
import hashlib
import getpass
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import time
from datetime import datetime, timezone
from typing import Any, Iterable
from urllib.parse import urlparse


class PipelineError(RuntimeError):
    pass


def read_dotenv(paths: Iterable[Path]) -> dict[str, str]:
    values: dict[str, str] = {}
    pattern = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$")
    for path in paths:
        if not path.is_file():
            continue
        for raw_line in path.read_text(encoding="utf-8-sig").splitlines():
            if not raw_line.strip() or raw_line.lstrip().startswith("#"):
                continue
            match = pattern.match(raw_line)
            if not match:
                continue
            key, value = match.groups()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            if value and key not in values:
                values[key] = value
    return values


def setting(explicit: str | None, dotenv: dict[str, str], name: str, *aliases: str) -> str:
    if explicit:
        return explicit
    for key in (name, *aliases):
        value = dotenv.get(key) or os.environ.get(key)
        if value:
            return value
    return ""


def run(
    args: list[str],
    *,
    checked: bool = True,
    capture: bool = False,
    quiet_stderr: bool = False,
) -> subprocess.CompletedProcess[str]:
    stderr = subprocess.DEVNULL if quiet_stderr else (subprocess.PIPE if capture else None)
    result = subprocess.run(
        args,
        check=False,
        stdout=subprocess.PIPE if capture else None,
        stderr=stderr,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if checked and result.returncode != 0:
        detail = f": {(result.stderr or '').strip()}" if capture and result.stderr else ""
        raise PipelineError(f"{' '.join(args)} failed with exit code {result.returncode}{detail}")
    return result


def docker(args: list[str], *, capture: bool = False, checked: bool = True) -> subprocess.CompletedProcess[str]:
    return run(["docker", *args], capture=capture, checked=checked)


def docker_with_retry(args: list[str], attempts: int = 3, delay_seconds: int = 5) -> None:
    for attempt in range(1, attempts + 1):
        result = docker(args, checked=False)
        if result.returncode == 0:
            return
        if attempt < attempts:
            print(f"Docker command failed (attempt {attempt}/{attempts}); retrying in {delay_seconds}s")
            time.sleep(delay_seconds)
    raise PipelineError(f"docker {' '.join(args)} failed after {attempts} attempts")


def phase(results: dict[str, Any], name: str, status: str, detail: str = "") -> None:
    results[name] = {"status": status, "detail": detail}
    print(f"[{status}] {name} {detail}".rstrip(), flush=True)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def make_source_archive(source: Path, output: Path) -> None:
    def include(info: tarfile.TarInfo) -> tarfile.TarInfo | None:
        parts = Path(info.name).parts
        return None if ".git" in parts or "node_modules" in parts else info

    with tarfile.open(output, "w:gz") as archive:
        archive.add(source, arcname=".", filter=include)


def remove_tree(path: Path) -> None:
    """Remove a directory tree, clearing read-only attributes on the way.

    ``shutil.rmtree`` refuses read-only files (git marks pack files read-only on
    Windows), which used to crash the cleanup path of an otherwise passing run.
    """
    def on_error(func, target, exc_info) -> None:  # noqa: ANN001 - shutil callback
        try:
            os.chmod(target, stat.S_IWRITE)
            func(target)
        except OSError:
            pass

    if path.exists():
        shutil.rmtree(path, onerror=on_error)


def resolve_style(value: str) -> str:
    """Single supported style: an OpenAI-compatible endpoint.

    Hermes' "openai-api" provider speaks it and honours model.base_url, and the
    memory plugin's standalone L1-L3 runner requires it too, so one URL serves
    both legs.
    """
    candidate = value.strip().lower()
    if candidate in {"", "openai", "openai-api"}:
        return "openai-api"
    raise PipelineError(
        f"HERMES_API_STYLE must be 'openai' (an OpenAI-compatible endpoint). Got: {value}"
    )


def infer_thinking(base_url: str) -> str:
    """Pick the plugin's disableThinking strategy from the endpoint host.

    The plugin only recognises false | vllm | deepseek | dashscope | openai |
    anthropic | kimi | gemini, and it injects a different request field per
    vendor, so unknown hosts fall back to "false" (inject nothing).
    """
    try:
        host = (urlparse(base_url).hostname or "").lower()
    except ValueError:
        host = ""
    for pattern, strategy in (
        (r"minimax", "anthropic"),
        (r"deepseek", "deepseek"),
        (r"dashscope|aliyun", "dashscope"),
        (r"anthropic", "anthropic"),
        (r"google|generativelanguage", "gemini"),
        (r"openai\.com|openrouter", "openai"),
    ):
        if re.search(pattern, host):
            return strategy
    return "false"


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Build Hermes, install memory_tencentdb, run soak, and verify L0-L3 recall")
    result.add_argument("--hermes-version", default="")
    result.add_argument("--week2-dir", default="")
    result.add_argument("--plugin-dir", default="")
    result.add_argument("--plugin-repo", default="https://github.com/Tencent/TencentDB-Agent-Memory.git")
    result.add_argument("--plugin-ref", default="main")
    result.add_argument("--config-volume", default="")
    result.add_argument("--model", default="")
    result.add_argument("--model-provider", "--api-style", dest="model_provider", default="")
    result.add_argument("--provider-api-key-env", default="")
    result.add_argument("--model-base-url", "--base-url", dest="model_base_url", default="")
    result.add_argument("--llm-base-url", "--tdai-llm-base-url", dest="llm_base_url", default="")
    result.add_argument("--models-endpoint", default="")
    result.add_argument("--disable-thinking", default="")
    result.add_argument("--rounds", type=int, default=8)
    result.add_argument("--keep-container", action="store_true")
    result.add_argument("--offline-dependencies", action="store_true")
    return result


def main() -> int:
    args = parser().parse_args()
    if args.rounds < 1:
        print("[fail] --rounds must be at least 1", file=sys.stderr)
        return 2

    pipeline_root = Path(__file__).resolve().parent
    dotenv = read_dotenv((Path.cwd() / ".env", pipeline_root / ".env"))
    hermes_version = setting(args.hermes_version, dotenv, "HERMES_VERSION")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", hermes_version):
        print("[fail] Hermes version is required: use --hermes-version x.y.z or set HERMES_VERSION in .env", file=sys.stderr)
        return 2

    model = setting(args.model, dotenv, "HERMES_MODEL", "OPENAI_MODEL")
    provider_value = setting(args.model_provider, dotenv, "HERMES_API_STYLE", "HERMES_MODEL_PROVIDER")
    provider_key_env = setting(args.provider_api_key_env, dotenv, "HERMES_PROVIDER_API_KEY_ENV")
    model_base_url = setting(args.model_base_url, dotenv, "HERMES_BASE_URL", "HERMES_MODEL_BASE_URL")
    llm_base_url = setting(args.llm_base_url, dotenv, "TDAI_LLM_BASE_URL", "HERMES_LLM_BASE_URL", "OPENAI_BASE_URL")
    api_key = setting(None, dotenv, "HERMES_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "MINIMAX_CN_API_KEY")
    disable_thinking = setting(args.disable_thinking, dotenv, "TDAI_LLM_DISABLE_THINKING")

    week2_dir = Path(args.week2_dir).expanduser().resolve() if args.week2_dir else pipeline_root
    dockerfile = week2_dir / "Dockerfile"
    advanced_source = pipeline_root.parent / "2-memory-l0l3"
    basic_source = pipeline_root.parent / "1-basic-soak"
    run_id = datetime.now().strftime("%Y%m%d_%H%M%S")
    output_dir = pipeline_root / "runs" / run_id
    evidence_dir = output_dir / "evidence"
    runtime_dir = evidence_dir / "runtime-data"
    work_dir = output_dir / "_work"
    generated_config_dir = work_dir / "config"
    cloned_plugin_dir = work_dir / "plugin"
    image_tag = f"hermes:week3-pipeline-{hermes_version}"
    container_name = f"hermes-pipeline-{run_id}"
    home_volume = f"hermes-pipeline-home-{run_id}"
    source_archive = output_dir / "tdai-source.tgz"
    summary_path = output_dir / "pipeline-summary.json"
    started_at = datetime.now(timezone.utc)
    phases: dict[str, Any] = {}
    container_created = False
    generated_config = False
    plugin_dir: Path | None = Path(args.plugin_dir).expanduser().resolve() if args.plugin_dir else None

    evidence_dir.mkdir(parents=True, exist_ok=True)
    runtime_dir.mkdir(parents=True, exist_ok=True)

    try:
        phase(phases, "bootstrap", "running", "preparing plugin and Hermes config")
        server = docker(["version", "--format", "{{.Server.Version}}"], capture=True)
        docker_server = (server.stdout or "").strip()

        if plugin_dir is None:
            work_dir.mkdir(parents=True, exist_ok=True)
            run(["git", "clone", "--depth", "1", "--branch", args.plugin_ref, args.plugin_repo, str(cloned_plugin_dir)])
            plugin_dir = cloned_plugin_dir

        if not args.config_volume:
            if not api_key and sys.stdin.isatty():
                api_key = getpass.getpass("Model API key is not set; enter it for this run: ").strip()
            if not api_key:
                raise PipelineError("A model API key is required; set HERMES_API_KEY in .env")
            if not model_base_url:
                raise PipelineError("HERMES_BASE_URL is required in .env")
            if not model:
                raise PipelineError("HERMES_MODEL is required in .env")
            model_provider = resolve_style(provider_value)
            if not llm_base_url:
                llm_base_url = model_base_url
            if not provider_key_env:
                provider_key_env = "OPENAI_API_KEY"
            if not disable_thinking:
                disable_thinking = infer_thinking(llm_base_url)

            generated_config_dir.mkdir(parents=True, exist_ok=True)
            env_text = "\n".join(
                [
                    f'HERMES_API_KEY="{api_key}"',
                    f'{provider_key_env}="{api_key}"',
                    f'TDAI_LLM_API_KEY="{api_key}"',
                    f'TDAI_LLM_BASE_URL="{llm_base_url}"',
                    f'TDAI_LLM_MODEL="{model}"',
                    'TDAI_LLM_TIMEOUT_MS="180000"',
                    f'TDAI_LLM_DISABLE_THINKING="{disable_thinking}"',
                    "",
                ]
            )
            config_text = "\n".join(
                [
                    "model:",
                    f"  default: {json.dumps(model, ensure_ascii=False)}",
                    f"  provider: {model_provider}",
                    f"  base_url: {json.dumps(model_base_url, ensure_ascii=False)}",
                    "_config_version: 39",
                    "memory:",
                    "  memory_enabled: false",
                    "  user_profile_enabled: false",
                    "",
                ]
            )
            (generated_config_dir / ".env").write_text(env_text, encoding="utf-8")
            (generated_config_dir / "config.yaml").write_text(config_text, encoding="utf-8")
            generated_config = True

        phase(phases, "bootstrap", "pass", f"docker={docker_server} plugin_ref={args.plugin_ref} generated_config={generated_config}")

        if not dockerfile.is_file():
            raise PipelineError(f"Week 2 Dockerfile not found: {dockerfile}")
        if plugin_dir is None or not (plugin_dir / "package.json").is_file():
            raise PipelineError(f"Plugin source not found: {plugin_dir}")
        if not (advanced_source / "fact-prompts.json").is_file():
            raise PipelineError(f"Fact prompts not found: {advanced_source}")

        phase(phases, "build", "running", f"image={image_tag}")
        docker_with_retry(["build", "--progress=plain", "--build-arg", f"HERMES_VERSION={hermes_version}", "-t", image_tag, str(week2_dir)])
        dockerfile_hash = sha256(dockerfile)
        phase(phases, "build", "pass", f"dockerfile_sha256={dockerfile_hash}")

        phase(phases, "prepare", "running", f"container={container_name}")
        make_source_archive(plugin_dir, source_archive)
        docker(["volume", "create", home_volume])
        if generated_config:
            docker(
                [
                    "run", "--rm", "--mount", f"type=bind,source={generated_config_dir},target=/source,readonly",
                    "-v", f"{home_volume}:/target", image_tag, "sh", "-c",
                    "cp /source/.env /target/.env; cp /source/config.yaml /target/config.yaml",
                ]
            )
        else:
            docker(
                [
                    "run", "--rm", "-v", f"{args.config_volume}:/source:ro", "-v", f"{home_volume}:/target",
                    image_tag, "sh", "-c", "cp /source/.env /target/.env; cp /source/config.yaml /target/config.yaml",
                ]
            )
        docker(
            [
                "run", "--name", container_name, "-dit", "-v", f"{home_volume}:/opt/hermes-home",
                "-v", f"{runtime_dir}:/opt/tdai-data", "-w", "/workspace/advanced", image_tag, "sh",
            ]
        )
        container_created = True
        docker(["cp", f"{advanced_source}{os.sep}.", f"{container_name}:/workspace/advanced"])
        docker(["cp", f"{basic_source}{os.sep}.", f"{container_name}:/workspace/soak"])
        docker(["cp", str(source_archive), f"{container_name}:/tmp/tdai-source.tgz"])
        docker(["exec", container_name, "sh", "-c", "mkdir -p /source/tdai /workspace/advanced; tar -xzf /tmp/tdai-source.tgz -C /source/tdai"])
        docker(["exec", container_name, "sh", "-c", "cp /workspace/advanced/npx-offline-wrapper.sh /usr/local/bin/npx; chmod +x /usr/local/bin/npx"])
        phase(phases, "prepare", "pass", "fresh_container=true")

        phase(phases, "install_plugin", "running")
        install_prefix = ["exec"]
        if args.offline_dependencies:
            offline_modules = advanced_source / "linux-install" / "package" / "node_modules"
            if not offline_modules.is_dir():
                raise PipelineError(f"Offline dependencies requested but not found: {offline_modules}")
            docker(["exec", container_name, "sh", "-c", "mkdir -p /opt/hermes-home/tdai-memory-plugin"])
            docker(["cp", str(offline_modules), f"{container_name}:/opt/hermes-home/tdai-memory-plugin/node_modules"])
            install_prefix += ["-e", "TDAI_SKIP_NPM_INSTALL=1"]
        docker([*install_prefix, container_name, "sh", "/workspace/advanced/install-plugin-in-container.sh"])
        phase(phases, "install_plugin", "pass", "provider=memory_tencentdb")

        phase(phases, "gateway", "running")
        docker(["exec", "-d", container_name, "sh", "/workspace/advanced/start-gateway-in-container.sh"])
        health = ""
        for _ in range(30):
            result = docker(["exec", container_name, "node", "/workspace/advanced/health-check.mjs"], capture=True, checked=False)
            health = (result.stdout or result.stderr or "").strip()
            if result.returncode == 0:
                break
            time.sleep(2)
        else:
            raise PipelineError(f"Gateway health check failed after 60s: {health}")
        phase(phases, "gateway", "pass", health)

        phase(phases, "soak", "running", f"rounds={args.rounds}")
        docker(
            [
                "exec", container_name, "node", "/workspace/advanced/../soak/hermes-soak.mjs",
                "--rounds", str(args.rounds), "--interval-ms", "1000", "--duration-minutes", "20",
                "--request-timeout-ms", "180000", "--toolsets", "context_engine,memory",
                "--prompts", "/workspace/advanced/fact-prompts.json", "--output", "/workspace/advanced/evidence/soak",
            ]
        )
        phase(phases, "soak", "pass", "meta.json generated")

        meta_result = docker(["exec", container_name, "sh", "-c", "cat /workspace/advanced/evidence/soak/meta.json"], capture=True)
        meta = json.loads(meta_result.stdout or "{}")
        if meta.get("status") != "pass":
            raise PipelineError(f"soak status={meta.get('status')}")
        session_id = str(meta.get("finalSessionId") or "")
        phase(phases, "verify_memory", "running", f"session={session_id}")
        docker(["exec", container_name, "node", "/workspace/advanced/verify-memory.mjs", "--session", session_id, "--timeout-seconds", "180"])
        phase(phases, "verify_memory", "pass", "L0-L3 and recall passed")

        docker(["cp", f"{container_name}:/workspace/advanced/evidence/.", str(evidence_dir)])
        finished_at = datetime.now(timezone.utc)
        summary = {
            "schemaVersion": 1,
            "status": "pass",
            "runId": run_id,
            "image": image_tag,
            "hermesVersion": hermes_version,
            "container": container_name,
            "dockerfile": str(dockerfile),
            "dockerfileSha256": dockerfile_hash,
            "startedAt": started_at.isoformat(),
            "finishedAt": finished_at.isoformat(),
            "elapsedMs": int((finished_at - started_at).total_seconds() * 1000),
            "phases": phases,
            "soak": meta,
            "evidenceDir": str(evidence_dir),
            "keptContainer": args.keep_container,
        }
        summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"PIPELINE PASS: {summary_path}")
        return 0
    except Exception as error:
        if container_created:
            docker(["cp", f"{container_name}:/workspace/advanced/evidence/.", str(evidence_dir)], checked=False)
        phases["error"] = {"status": "fail", "detail": str(error)}
        failed = {
            "schemaVersion": 1,
            "status": "fail",
            "runId": run_id,
            "image": image_tag,
            "container": container_name,
            "phases": phases,
        }
        summary_path.write_text(json.dumps(failed, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"[fail] {error}", file=sys.stderr)
        print(f"Evidence: {summary_path}", file=sys.stderr)
        return 1
    finally:
        # Cleanup is best effort: it must never turn a passing run into a failing one.
        try:
            if container_created:
                docker(["exec", container_name, "sh", "-c", "rm -f /opt/hermes-home/.env"], checked=False)
                if not args.keep_container:
                    docker(["rm", "-f", container_name], checked=False)
            if source_archive.exists():
                source_archive.unlink()
            remove_tree(work_dir)
        except Exception as cleanup_error:  # noqa: BLE001 - best-effort cleanup
            print(f"[warn] cleanup incomplete: {cleanup_error}", file=sys.stderr)
        api_key = ""


if __name__ == "__main__":
    raise SystemExit(main())
