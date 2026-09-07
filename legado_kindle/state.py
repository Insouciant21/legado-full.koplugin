"""Versioned on-device state directory for the Kindle port."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import os
import shutil
import tempfile
from typing import Any

from .backup import BackupBundle, BackupError, JSON_BACKUP_FILES, _validate_member_name


STATE_SCHEMA_VERSION = 1


class StateError(ValueError):
    """Raised when a Kindle state directory is invalid."""


def _member_kind(name: str) -> str:
    if name in JSON_BACKUP_FILES:
        return "json"
    if name == "config.xml":
        return "xml"
    return "opaque"


@dataclass(frozen=True)
class StateDirectory:
    root: Path

    @property
    def manifest_path(self) -> Path:
        return self.root / "manifest.json"

    @property
    def android_path(self) -> Path:
        return self.root / "android"

    def manifest(self) -> dict[str, Any]:
        try:
            data = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise StateError(f"invalid state manifest: {exc}") from exc
        if not isinstance(data, dict):
            raise StateError("invalid state manifest")
        if data.get("state_schema_version") != STATE_SCHEMA_VERSION:
            raise StateError("unsupported state schema version")
        if data.get("format") != "legado-android-backup":
            raise StateError("unsupported state format")
        return data

    def load_bundle(self) -> BackupBundle:
        manifest = self.manifest()
        if not self.android_path.is_dir():
            raise StateError("state directory has no android member directory")
        expected: dict[str, dict[str, Any]] = {}
        manifest_members = manifest.get("members")
        if not isinstance(manifest_members, list):
            raise StateError("state manifest has no member list")
        for item in manifest_members:
            if not isinstance(item, dict) or not isinstance(item.get("name"), str):
                raise StateError("state manifest has an invalid member entry")
            _validate_member_name(item["name"])
            if item["name"] in expected:
                raise StateError(f"duplicate state manifest member: {item['name']}")
            if item.get("kind") != _member_kind(item["name"]):
                raise StateError(f"state member kind mismatch: {item['name']}")
            if not isinstance(item.get("size"), int) or item["size"] < 0:
                raise StateError(f"state member size is invalid: {item['name']}")
            expected[item["name"]] = item
        members: dict[str, bytes] = {}
        for file in self.android_path.iterdir():
            if not file.is_file():
                continue
            _validate_member_name(file.name)
            data = file.read_bytes()
            info = expected.get(file.name)
            if info is None:
                raise StateError(f"state member is not listed in manifest: {file.name}")
            if info["size"] != len(data):
                raise StateError(f"state member size mismatch: {file.name}")
            # The Kindle Lua implementation intentionally omits a hash because
            # KOReader's base does not expose a stable hashing API.  Desktop
            # state manifests include it and are checked when present.
            expected_hash = info.get("sha256")
            if expected_hash is not None and expected_hash != hashlib.sha256(data).hexdigest():
                raise StateError(f"state member hash mismatch: {file.name}")
            members[file.name] = data
        if set(members) != set(expected):
            missing = sorted(set(expected) - set(members))
            extra = sorted(set(members) - set(expected))
            raise StateError(f"state manifest/member mismatch: missing={missing}, extra={extra}")
        bundle = BackupBundle.load_from_members(members)
        return bundle


def _manifest_for(bundle: BackupBundle) -> dict[str, Any]:
    members = []
    for name in sorted(bundle.members):
        data = bundle.members[name]
        members.append(
            {
                "name": name,
                "size": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
                "kind": _member_kind(name),
            }
        )
    return {
        "state_schema_version": STATE_SCHEMA_VERSION,
        "format": "legado-android-backup",
        "members": members,
        "summary": bundle.summary().as_dict(),
    }


def import_bundle(bundle: BackupBundle, destination: str | os.PathLike[str]) -> StateDirectory:
    """Materialize a backup into a new state directory.

    The destination must not already exist. A staging directory is used so a
    failed import cannot leave a partially populated state behind.
    """

    target = Path(destination)
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        raise StateError(f"state destination already exists: {target}")

    staging_name = tempfile.mkdtemp(prefix=f".{target.name}.", dir=target.parent)
    staging = Path(staging_name)
    try:
        android = staging / "android"
        android.mkdir()
        for name, data in bundle.members.items():
            _validate_member_name(name)
            (android / name).write_bytes(data)
        (staging / "manifest.json").write_text(
            json.dumps(_manifest_for(bundle), ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        os.replace(staging, target)
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return StateDirectory(target)


def export_state(state: StateDirectory, destination: str | os.PathLike[str]) -> None:
    """Create an Android-shaped ZIP from a Kindle state directory."""

    bundle = state.load_bundle()
    bundle.write(destination)
