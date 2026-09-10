"""Read-only import support for Legado Android backup archives.

The Kindle port deliberately has a narrow backup boundary.  An Android
archive is an input source for the data the plugin can use:

* book sources (including every source rule and login field);
* the bookshelf;
* Android reading-history records.

Android reader preferences, themes, servers, RSS data, search history and
other settings are ignored and are never copied to the Kindle state directory.
KOReader remains the owner of font, layout, CSS and document presentation.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import os
from typing import Any, Iterable
import zipfile


IMPORT_MEMBERS: tuple[str, ...] = (
    "bookSource.json",
    "bookshelf.json",
    "readRecord.json",
    "readRecordDetail.json",
    "readRecordSession.json",
)
JSON_IMPORT_MEMBERS = frozenset(IMPORT_MEMBERS)
CORE_MEMBERS = frozenset({"bookSource.json", "bookshelf.json"})
RECORD_MEMBERS = frozenset(
    {"readRecord.json", "readRecordDetail.json", "readRecordSession.json"}
)


class BackupError(ValueError):
    """Raised when an archive cannot be safely imported."""


def _union_object_keys(values: Any) -> list[str]:
    keys: set[str] = set()
    if isinstance(values, dict):
        keys.update(str(key) for key in values)
    elif isinstance(values, list):
        for value in values:
            if isinstance(value, dict):
                keys.update(str(key) for key in value)
    return sorted(keys)


def _rule_keys(sources: list[dict[str, Any]], field: str) -> list[str]:
    keys: set[str] = set()
    for source in sources:
        rule = source.get(field)
        if isinstance(rule, dict):
            keys.update(str(key) for key in rule)
    return sorted(keys)


def _count_nonempty(values: Iterable[Any]) -> int:
    return sum(value not in (None, "", [], {}) for value in values)


def _collection_count(value: Any) -> int:
    if isinstance(value, list):
        return len(value)
    if isinstance(value, dict):
        # A few older exports use one record object instead of a one-element
        # array. Do not report its field count as the record count.
        if "bookName" in value or "bookAuthor" in value:
            return 1
        return len(value)
    return 0


def _validate_member_name(name: str) -> None:
    # Android backup members are flat. Reject absolute paths, traversal, and
    # Windows separators before any member is considered.
    if not name or name in {".", ".."} or "/" in name or "\\" in name:
        raise BackupError(f"unsafe ZIP member name: {name!r}")


def _encode_json(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def _sanitize_bookshelf(value: Any) -> list[Any]:
    if not isinstance(value, list):
        raise BackupError("bookshelf.json must be a JSON array")

    sanitized: list[Any] = []
    for book in value:
        if isinstance(book, dict):
            # readConfig is Android reader UI configuration (font, colors,
            # margins, and related options). The group fields belong to
            # Android's bookshelf classifier, not the Kindle model.
            sanitized.append(
                {
                    key: child
                    for key, child in book.items()
                    if key
                    not in {"readConfig", "group", "groupId", "bookGroupId", "bookGroup"}
                }
            )
        else:
            sanitized.append(book)
    return sanitized


def _parse_member(name: str, data: bytes) -> tuple[Any, bytes]:
    try:
        value = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BackupError(f"{name} is not valid UTF-8 JSON: {exc}") from exc

    if name in CORE_MEMBERS and not isinstance(value, list):
        raise BackupError(f"{name} must be a JSON array")
    if name in RECORD_MEMBERS and not isinstance(value, (list, dict)):
        raise BackupError(f"{name} must be a JSON array or object")
    if name == "bookshelf.json":
        value = _sanitize_bookshelf(value)
        data = _encode_json(value)
    return value, data


@dataclass(frozen=True)
class MemberInfo:
    name: str
    file_size: int
    sha256: str
    kind: str = "json"

    def as_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "file_size": self.file_size,
            "sha256": self.sha256,
            "kind": self.kind,
        }


@dataclass(frozen=True)
class BackupSummary:
    member_count: int
    ignored_files: tuple[str, ...]
    members: tuple[MemberInfo, ...]
    counts: dict[str, Any]
    feature_usage: dict[str, int]
    rule_keys: dict[str, list[str]]
    top_level_keys: dict[str, list[str]]

    def as_dict(self) -> dict[str, Any]:
        return {
            "member_count": self.member_count,
            "ignored_files": list(self.ignored_files),
            "members": [member.as_dict() for member in self.members],
            "counts": self.counts,
            "feature_usage": self.feature_usage,
            "rule_keys": self.rule_keys,
            "top_level_keys": self.top_level_keys,
        }


class BackupBundle:
    """The sanitized import result for the five supported members."""

    def __init__(
        self,
        members: dict[str, bytes],
        parsed_json: dict[str, Any],
        source_path: Path | None = None,
        ignored_files: Iterable[str] = (),
    ) -> None:
        self.members = members
        self.parsed_json = parsed_json
        self.source_path = source_path
        self.ignored_files = tuple(ignored_files)

    @classmethod
    def load(cls, path: str | os.PathLike[str]) -> "BackupBundle":
        archive_path = Path(path)
        if not archive_path.is_file():
            raise BackupError(f"backup does not exist: {archive_path}")

        members: dict[str, bytes] = {}
        parsed_json: dict[str, Any] = {}
        ignored_files: list[str] = []
        try:
            with zipfile.ZipFile(archive_path, "r") as archive:
                for info in archive.infolist():
                    if info.is_dir():
                        continue
                    _validate_member_name(info.filename)
                    # Do not even read ignored members. In particular this
                    # prevents a malformed Android-only settings file from
                    # breaking an otherwise usable import.
                    if info.filename not in JSON_IMPORT_MEMBERS:
                        ignored_files.append(info.filename)
                        continue
                    if info.filename in members:
                        raise BackupError(f"duplicate ZIP member: {info.filename}")
                    value, sanitized_data = _parse_member(
                        info.filename, archive.read(info)
                    )
                    members[info.filename] = sanitized_data
                    parsed_json[info.filename] = value
        except zipfile.BadZipFile as exc:
            raise BackupError(f"invalid ZIP archive: {exc}") from exc
        except RuntimeError as exc:
            raise BackupError(f"unable to read ZIP archive: {exc}") from exc

        for name in IMPORT_MEMBERS:
            if name not in members:
                raise BackupError(f"backup is missing required member: {name}")
        return cls(members, parsed_json, archive_path, ignored_files)

    @classmethod
    def load_from_members(cls, members: dict[str, bytes]) -> "BackupBundle":
        """Build a sanitized bundle from state member bytes."""

        selected: dict[str, bytes] = {}
        parsed_json: dict[str, Any] = {}
        for name in IMPORT_MEMBERS:
            if name not in members:
                raise BackupError(f"state is missing required member: {name}")
            value, sanitized_data = _parse_member(name, members[name])
            selected[name] = sanitized_data
            parsed_json[name] = value
        return cls(selected, parsed_json)

    def summary(self) -> BackupSummary:
        sources = self.parsed_json["bookSource.json"]
        books = self.parsed_json["bookshelf.json"]
        source_dicts = [source for source in sources if isinstance(source, dict)]
        infos = tuple(
            MemberInfo(
                name=name,
                file_size=len(self.members[name]),
                sha256=hashlib.sha256(self.members[name]).hexdigest(),
            )
            for name in IMPORT_MEMBERS
        )
        feature_usage = {
            "sources_with_explore_url": _count_nonempty(
                source.get("exploreUrl") for source in source_dicts
            ),
            "sources_with_main_js": _count_nonempty(
                source.get("mainJs") for source in source_dicts
            ),
            "sources_with_js_lib": _count_nonempty(
                source.get("jsLib") for source in source_dicts
            ),
            "sources_with_login_url": _count_nonempty(
                source.get("loginUrl") for source in source_dicts
            ),
            "sources_with_login_ui": _count_nonempty(
                source.get("loginUi") for source in source_dicts
            ),
            "sources_with_cookie_jar": sum(
                source.get("enabledCookieJar") is True for source in source_dicts
            ),
            "sources_with_header": _count_nonempty(
                source.get("header") for source in source_dicts
            ),
            "sources_with_content_next_url": _count_nonempty(
                (source.get("ruleContent") or {}).get("nextContentUrl")
                if isinstance(source.get("ruleContent"), dict)
                else None
                for source in source_dicts
            ),
            "sources_with_toc_next_url": _count_nonempty(
                (source.get("ruleToc") or {}).get("nextTocUrl")
                if isinstance(source.get("ruleToc"), dict)
                else None
                for source in source_dicts
            ),
        }
        return BackupSummary(
            member_count=len(self.members),
            ignored_files=self.ignored_files,
            members=infos,
            counts={
                "book_sources": len(sources),
                "bookshelf_books": len(books),
                "read_records": _collection_count(
                    self.parsed_json["readRecord.json"]
                ),
                "read_record_details": _collection_count(
                    self.parsed_json["readRecordDetail.json"]
                ),
                "read_record_sessions": _collection_count(
                    self.parsed_json["readRecordSession.json"]
                ),
                "ignored_members": len(self.ignored_files),
            },
            feature_usage=feature_usage,
            rule_keys={
                field: _rule_keys(source_dicts, field)
                for field in (
                    "ruleBookInfo",
                    "ruleContent",
                    "ruleExplore",
                    "ruleSearch",
                    "ruleToc",
                )
            },
            top_level_keys={
                name: _union_object_keys(self.parsed_json[name])
                for name in IMPORT_MEMBERS
            },
        )

    def json(self, filename: str) -> Any:
        if filename not in JSON_IMPORT_MEMBERS:
            raise BackupError(f"not an imported JSON member: {filename}")
        return self.parsed_json[filename]

    def replace_json(self, filename: str, value: Any) -> None:
        if filename not in JSON_IMPORT_MEMBERS:
            raise BackupError(f"not an editable imported JSON member: {filename}")
        if filename in CORE_MEMBERS and not isinstance(value, list):
            raise BackupError(f"{filename} must be a JSON array")
        if filename in RECORD_MEMBERS and not isinstance(value, (list, dict)):
            raise BackupError(f"{filename} must be a JSON array or object")
        if filename == "bookshelf.json":
            value = _sanitize_bookshelf(value)
        self.parsed_json[filename] = value
        self.members[filename] = _encode_json(value)
