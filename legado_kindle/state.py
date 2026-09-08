"""Small on-device state directory for imported Legado data."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import os
import shutil
import tempfile
from typing import Any

from .backup import BackupBundle, IMPORT_MEMBERS, _validate_member_name


STATE_SCHEMA_VERSION = 2
STATE_FORMAT = "legado-imported-data"


class StateError(ValueError):
    """Raised when a Kindle state directory is invalid."""


@dataclass(frozen=True)
class StateDirectory:
    root: Path

    @property
    def manifest_path(self) -> Path:
        return self.root / "manifest.json"

    @property
    def sources_path(self) -> Path:
        return self.root / "bookSource.json"

    @property
    def bookshelf_path(self) -> Path:
        return self.root / "bookshelf.json"

    @property
    def groups_path(self) -> Path:
        return self.root / "bookGroup.json"

    def member_path(self, name: str) -> Path:
        if name not in IMPORT_MEMBERS:
            raise StateError(f"unsupported state member: {name}")
        return self.root / name

    def manifest(self) -> dict[str, Any]:
        try:
            data = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise StateError(f"invalid state manifest: {exc}") from exc
        if not isinstance(data, dict):
            raise StateError("invalid state manifest")
        if data.get("state_schema_version") != STATE_SCHEMA_VERSION:
            raise StateError("unsupported state schema version")
        if data.get("format") != STATE_FORMAT:
            raise StateError("unsupported state format")
        return data

    def load_bundle(self) -> BackupBundle:
        manifest = self.manifest()
        expected: dict[str, dict[str, Any]] = {}
        manifest_members = manifest.get("members")
        if not isinstance(manifest_members, list):
            raise StateError("state manifest has no member list")
        for item in manifest_members:
            if not isinstance(item, dict) or not isinstance(item.get("name"), str):
                raise StateError("state manifest has an invalid member entry")
            name = item["name"]
            _validate_member_name(name)
            if name not in IMPORT_MEMBERS:
                raise StateError(f"state manifest contains an unsupported member: {name}")
            if name in expected:
                raise StateError(f"duplicate state manifest member: {name}")
            if item.get("kind") != "json":
                raise StateError(f"state member kind mismatch: {name}")
            if not isinstance(item.get("size"), int) or item["size"] < 0:
                raise StateError(f"state member size is invalid: {name}")
            expected[name] = item

        if set(expected) != set(IMPORT_MEMBERS):
            missing = sorted(set(IMPORT_MEMBERS) - set(expected))
            extra = sorted(set(expected) - set(IMPORT_MEMBERS))
            if missing:
                raise StateError(f"state manifest is missing members: {missing}")
            raise StateError(f"state manifest contains extra members: {extra}")

        allowed = set(IMPORT_MEMBERS) | {"manifest.json"}
        try:
            children = list(self.root.iterdir())
        except OSError as exc:
            raise StateError(f"cannot read state directory: {exc}") from exc
        for child in children:
            if child.name not in allowed:
                raise StateError(f"state contains an unsupported file: {child.name}")
            if child.name != "manifest.json" and not child.is_file():
                raise StateError(f"state member is not a file: {child.name}")

        members: dict[str, bytes] = {}
        for name in IMPORT_MEMBERS:
            path = self.root / name
            if not path.is_file():
                raise StateError(f"state member is missing: {name}")
            data = path.read_bytes()
            info = expected[name]
            if info["size"] != len(data):
                raise StateError(f"state member size mismatch: {name}")
            expected_hash = info.get("sha256")
            if expected_hash is not None and expected_hash != hashlib.sha256(data).hexdigest():
                raise StateError(f"state member hash mismatch: {name}")
            members[name] = data

        try:
            return BackupBundle.load_from_members(members)
        except ValueError as exc:
            raise StateError(str(exc)) from exc


def _manifest_for(bundle: BackupBundle) -> dict[str, Any]:
    members = []
    for name in IMPORT_MEMBERS:
        data = bundle.members[name]
        members.append(
            {
                "name": name,
                "size": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
                "kind": "json",
            }
        )
    return {
        "state_schema_version": STATE_SCHEMA_VERSION,
        "format": STATE_FORMAT,
        "members": members,
        "summary": bundle.summary().as_dict(),
    }


def import_bundle(bundle: BackupBundle, destination: str | os.PathLike[str]) -> StateDirectory:
    """Materialize only the six supported import members at state root."""

    target = Path(destination)
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        raise StateError(f"state destination already exists: {target}")

    staging_name = tempfile.mkdtemp(prefix=f".{target.name}.", dir=target.parent)
    staging = Path(staging_name)
    try:
        for name in IMPORT_MEMBERS:
            _validate_member_name(name)
            (staging / name).write_bytes(bundle.members[name])
        (staging / "manifest.json").write_text(
            json.dumps(_manifest_for(bundle), ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        os.replace(staging, target)
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return StateDirectory(target)
