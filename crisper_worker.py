#!/usr/bin/env python3
"""Persistent JSON-lines worker for the TypeWhisper CrisperWhisper plugin.

Protocol input/output is one UTF-8 JSON object per line. All ordinary stdout
from imported libraries is redirected to stderr so it cannot corrupt protocol
responses.
"""

from __future__ import annotations

import gc
import importlib.metadata
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import platform
import sys
import time
import traceback
import types
from dataclasses import dataclass
from typing import Any, TextIO

EXPECTED_CRISPERWHISPER_VERSION = "2.0.1"
VALID_MODELS = {"large", "medium", "small", "turbo"}
VALID_MODES = {"verbatim", "intended"}
MAX_REQUEST_BYTES = 1_048_576

# Keep the protocol stream pristine. Libraries that print() during import/model
# loading are redirected to stderr instead of breaking JSON parsing in Swift.
_PROTOCOL_STDOUT: TextIO = sys.stdout
try:
    sys.stderr.reconfigure(line_buffering=True)
except Exception:
    pass
sys.stdout = sys.stderr


def _configure_logging() -> logging.Logger:
    handlers: list[logging.Handler] = [logging.StreamHandler(sys.stderr)]
    log_path = os.environ.get("CRISPERWHISPER_LOG_FILE")
    if log_path:
        path = Path(log_path).expanduser()
        path.parent.mkdir(parents=True, exist_ok=True)
        handlers.append(
            RotatingFileHandler(
                path,
                maxBytes=2_000_000,
                backupCount=2,
                encoding="utf-8",
            )
        )
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        handlers=handlers,
        force=True,
    )
    return logging.getLogger("crisperwhisper.typewhisper.worker")


LOGGER = _configure_logging()
_CTRANSLATE2_SHIM_ACTIVE = False


def _emit(payload: dict[str, Any]) -> None:
    _PROTOCOL_STDOUT.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
    _PROTOCOL_STDOUT.flush()


def _package_version(name: str) -> str:
    try:
        return importlib.metadata.version(name)
    except importlib.metadata.PackageNotFoundError:
        return "not-installed"


def _install_transformers_hallucination_shim() -> None:
    """Allow Transformers-only repair helpers to load without CT2 on macOS.

    CrisperWhisper 2.0.1's backend-neutral loop detector lives in a module
    that imports ctranslate2 for CT2-only helpers. The project's CT2 fork has
    no macOS wheel, but the Transformers repair path only uses the pure-Python
    loop detector. A deliberately empty module is therefore sufficient for
    this backend while keeping CT2 unavailable for backend selection.
    """
    global _CTRANSLATE2_SHIM_ACTIVE
    try:
        import ctranslate2  # noqa: F401
    except ModuleNotFoundError as exc:
        if exc.name != "ctranslate2":
            raise
        shim = types.ModuleType("ctranslate2")
        shim.__doc__ = "Transformers-only compatibility shim"
        sys.modules["ctranslate2"] = shim
        _CTRANSLATE2_SHIM_ACTIVE = True


def _validate_environment() -> None:
    actual = _package_version("crisperwhisper")
    if actual != EXPECTED_CRISPERWHISPER_VERSION:
        raise RuntimeError(
            "Unsupported crisperwhisper version "
            f"{actual!r}; expected {EXPECTED_CRISPERWHISPER_VERSION!r}. "
            "Run the supplied setup.sh again."
        )
    _install_transformers_hallucination_shim()
    from crisperwhisper.hallucination import find_token_loop

    if not callable(find_token_loop):
        raise RuntimeError("CrisperWhisper loop-repair helper is unavailable")


@dataclass
class LoadedModel:
    name: str
    device: str
    compute_type: str
    instance: Any
    load_seconds: float


class ModelManager:
    def __init__(self) -> None:
        self._loaded: LoadedModel | None = None
        self._torch: Any | None = None

    @property
    def loaded(self) -> LoadedModel | None:
        return self._loaded

    def _get_torch(self) -> Any:
        if self._torch is None:
            import torch

            requested_threads = os.environ.get("CRISPERWHISPER_CPU_THREADS")
            if requested_threads:
                threads = max(1, int(requested_threads))
            else:
                threads = max(1, min(os.cpu_count() or 4, 8))
            torch.set_num_threads(threads)
            self._torch = torch
        return self._torch

    def _mps_is_available(self) -> bool:
        torch = self._get_torch()
        backend = getattr(torch.backends, "mps", None)
        return bool(
            sys.platform == "darwin"
            and platform.machine() == "arm64"
            and backend is not None
            and backend.is_available()
        )

    def preferred_runtime(self, policy: str) -> tuple[str, str]:
        normalized = (policy or "mps-preferred").strip().lower()
        if normalized not in {"mps-preferred", "mps", "cpu", "auto"}:
            raise ValueError(f"Invalid device policy: {policy!r}")
        if normalized == "cpu":
            return "cpu", "float32"
        if self._mps_is_available():
            return "mps", "float16"
        if normalized == "mps":
            raise RuntimeError("MPS was explicitly requested but is unavailable")
        return "cpu", "float32"

    def unload(self) -> None:
        loaded = self._loaded
        self._loaded = None
        if loaded is not None:
            LOGGER.info("Unloading model=%s device=%s", loaded.name, loaded.device)
            del loaded
        gc.collect()
        try:
            torch = self._get_torch()
            if hasattr(torch, "mps") and torch.backends.mps.is_available():
                torch.mps.empty_cache()
        except Exception:
            LOGGER.debug("Unable to empty accelerator cache", exc_info=True)

    def load(self, name: str, device: str, compute_type: str) -> LoadedModel:
        if name not in VALID_MODELS:
            raise ValueError(f"Unsupported model shorthand: {name!r}")

        current = self._loaded
        if (
            current is not None
            and current.name == name
            and current.device == device
            and current.compute_type == compute_type
        ):
            return current

        self.unload()
        from crisperwhisper import CrisperWhisperModel

        LOGGER.info(
            "Loading CrisperWhisper model=%s backend=transformers device=%s dtype=%s",
            name,
            device,
            compute_type,
        )
        started = time.perf_counter()
        instance = CrisperWhisperModel(
            name,
            backend="transformers",
            device=device,
            compute_type=compute_type,
        )
        loaded = LoadedModel(
            name=name,
            device=device,
            compute_type=compute_type,
            instance=instance,
            load_seconds=round(time.perf_counter() - started, 3),
        )
        self._loaded = loaded
        LOGGER.info("Model loaded in %.3fs", loaded.load_seconds)
        return loaded

    @staticmethod
    def detect_language(loaded: LoadedModel, audio_path: Path) -> str:
        """Detect an ISO 639-1 language with the loaded Whisper model."""
        from crisperwhisper.audio import load_audio

        engine = getattr(loaded.instance, "_engine", None)
        model = getattr(engine, "model", None)
        generation_config = getattr(model, "generation_config", None)
        lang_to_id = getattr(generation_config, "lang_to_id", None)
        if engine is None or model is None or not lang_to_id:
            raise RuntimeError("Loaded model does not expose language detection")

        audio = load_audio(audio_path)
        features = engine.extract_features(audio)
        detected_ids = model.detect_language(
            input_features=features,
            generation_config=generation_config,
        )
        detected_id = int(detected_ids[0].item())
        token = next(
            (token for token, token_id in lang_to_id.items() if int(token_id) == detected_id),
            None,
        )
        if token is None or not token.startswith("<|") or not token.endswith("|>"):
            raise RuntimeError(f"Unknown detected language token id: {detected_id}")
        language = token[2:-2].lower()
        if len(language) != 2 or not language.isalpha():
            raise RuntimeError(f"Invalid detected language token: {token}")
        LOGGER.info("Detected language=%s", language)
        return language

    @staticmethod
    def is_mps_failure(exc: BaseException) -> bool:
        message = f"{type(exc).__name__}: {exc}".lower()
        indicators = (
            "mps",
            "metal",
            "not implemented for",
            "placeholder storage",
            "unsupported dtype",
            "out of memory",
            "expected scalar type",
        )
        return any(indicator in message for indicator in indicators)


MODELS = ModelManager()


def _require_string(request: dict[str, Any], key: str) -> str:
    value = request.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{key} must be a non-empty string")
    return value.strip()


def _transcribe(request: dict[str, Any]) -> dict[str, Any]:
    request_id = _require_string(request, "request_id")
    audio_path = Path(_require_string(request, "audio_path")).expanduser().resolve()
    model_name = _require_string(request, "model").lower()
    requested_language = _require_string(request, "language").lower()
    mode = _require_string(request, "mode").lower()
    device_policy = str(request.get("device_policy", "mps-preferred")).lower()

    if model_name not in VALID_MODELS:
        raise ValueError(f"model must be one of {sorted(VALID_MODELS)}")
    if mode not in VALID_MODES:
        raise ValueError(f"mode must be one of {sorted(VALID_MODES)}")
    if not audio_path.is_file():
        raise FileNotFoundError(f"Audio file does not exist: {audio_path}")
    if audio_path.stat().st_size <= 44:
        raise ValueError("Audio WAV is empty or invalid")

    device, compute_type = MODELS.preferred_runtime(device_policy)

    try:
        loaded = MODELS.load(model_name, device, compute_type)
        language = (
            MODELS.detect_language(loaded, audio_path)
            if requested_language == "auto"
            else requested_language
        )
        result = loaded.instance.transcribe(
            audio_path,
            language=language,
            mode=mode,
            word_timestamps=False,
            hallucination_mitigation=True,
            early_eot_recovery=True,
        )
    except Exception as first_error:
        if device == "mps" and device_policy in {"mps-preferred", "auto"} and MODELS.is_mps_failure(first_error):
            LOGGER.warning(
                "MPS inference failed; retrying once on CPU: %s",
                first_error,
            )
            MODELS.unload()
            loaded = MODELS.load(model_name, "cpu", "float32")
            try:
                language = (
                    MODELS.detect_language(loaded, audio_path)
                    if requested_language == "auto"
                    else requested_language
                )
                result = loaded.instance.transcribe(
                    audio_path,
                    language=language,
                    mode=mode,
                    word_timestamps=False,
                    hallucination_mitigation=True,
                    early_eot_recovery=True,
                )
            except Exception as cpu_error:
                raise RuntimeError(
                    "MPS failed and the CPU retry also failed. "
                    f"MPS: {first_error}; CPU: {cpu_error}"
                ) from cpu_error
        else:
            raise

    text = str(getattr(result, "text", "")).strip()
    if not text:
        LOGGER.info("Transcription completed with empty text")

    return {
        "request_id": request_id,
        "status": "success",
        "text": text,
        "language": str(getattr(result, "language", language)),
        "mode": str(getattr(result, "mode", mode)),
        "model": loaded.name,
        "device": loaded.device,
        "compute_type": loaded.compute_type,
        "model_load_seconds": loaded.load_seconds,
        "processing_time": float(getattr(result, "processing_time", 0.0)),
        "duration": float(getattr(result, "duration", 0.0)),
    }


def _ping(request: dict[str, Any]) -> dict[str, Any]:
    request_id = str(request.get("request_id", "ping"))
    torch = MODELS._get_torch()
    return {
        "request_id": request_id,
        "status": "success",
        "command": "pong",
        "python": platform.python_version(),
        "crisperwhisper": _package_version("crisperwhisper"),
        "transformers_hallucination_shim": _CTRANSLATE2_SHIM_ACTIVE,
        "torch": _package_version("torch"),
        "mps_available": MODELS._mps_is_available(),
        "loaded_model": MODELS.loaded.name if MODELS.loaded else None,
        "loaded_device": MODELS.loaded.device if MODELS.loaded else None,
        "torch_threads": torch.get_num_threads(),
    }


def _handle(request: dict[str, Any]) -> dict[str, Any]:
    command = _require_string(request, "command").lower()
    if command == "transcribe":
        return _transcribe(request)
    if command == "ping":
        return _ping(request)
    if command == "unload":
        MODELS.unload()
        return {
            "request_id": str(request.get("request_id", "unload")),
            "status": "success",
            "command": "unloaded",
        }
    if command == "shutdown":
        MODELS.unload()
        return {
            "request_id": str(request.get("request_id", "shutdown")),
            "status": "success",
            "command": "shutdown",
        }
    raise ValueError(f"Unknown command: {command!r}")


def main() -> int:
    try:
        _validate_environment()
    except Exception as exc:
        LOGGER.exception("Worker environment validation failed")
        _emit(
            {
                "request_id": "startup",
                "status": "error",
                "error_type": type(exc).__name__,
                "message": str(exc),
            }
        )
        return 2

    LOGGER.info(
        "Worker started: Python %s, crisperwhisper %s",
        platform.python_version(),
        _package_version("crisperwhisper"),
    )

    while True:
        raw = sys.stdin.buffer.readline(MAX_REQUEST_BYTES + 1)
        if not raw:
            break
        if len(raw) > MAX_REQUEST_BYTES:
            _emit(
                {
                    "request_id": "unknown",
                    "status": "error",
                    "error_type": "ValueError",
                    "message": "Request exceeds maximum protocol line size",
                }
            )
            continue
        if not raw.strip():
            continue

        request_id = "unknown"
        command = ""
        try:
            request = json.loads(raw.decode("utf-8"))
            if not isinstance(request, dict):
                raise ValueError("Request must be a JSON object")
            request_id = str(request.get("request_id", "unknown"))
            command = str(request.get("command", ""))
            response = _handle(request)
            _emit(response)
            if command.lower() == "shutdown":
                break
        except Exception as exc:
            LOGGER.error("Request %s failed: %s", request_id, exc)
            LOGGER.debug("Full traceback:\n%s", traceback.format_exc())
            _emit(
                {
                    "request_id": request_id,
                    "status": "error",
                    "error_type": type(exc).__name__,
                    "message": str(exc),
                }
            )

    MODELS.unload()
    LOGGER.info("Worker stopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
