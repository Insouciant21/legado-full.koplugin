"""Safe structural handling for Legado Android backup archives.

The backup format is intentionally treated as a compatibility boundary. Known
JSON files are parsed for migration, while Android-specific or currently
unsupported files are retained byte-for-byte so a Kindle export can preserve
them for Android restoration.
"""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import os
import tempfile
from typing import Any, Iterable
from xml.etree import ElementTree
import zipfile


ANDROID_BACKUP_FILES: tuple[str, ...] = (
    "bookshelf.json",
    "bookGroup.json",
    "bookSource.json",
    "rssSources.json",
    "readRecord.json",
    "readRecordDetail.json",
    "readRecordSession.json",
    "searchHistory.json",
    "txtTocRule.json",
    "httpTTS.json",
    "keyboardAssists.json",
    "dictRule.json",
    "servers.json",
    "readConfig.json",
    "shareReadConfig.json",
    "themeConfig.json",
    "config.xml",
)

JSON_BACKUP_FILES = frozenset(
    name for name in ANDROID_BACKUP_FILES if name not in {"servers.json", "config.xml"}
)
OPAQUE_BACKUP_FILES = frozenset({"servers.json", "config.xml"})


class BackupError(ValueError):
    """Raised when an archive cannot be safely interpreted."""


def _is_empty(value: Any) -> bool:
    return value is None or value == "" or value == [] or value == {}


def _walk_strings(value: Any) -> Iterable[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for child in value.values():
            yield from _walk_strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from _walk_strings(child)


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
    return sum(not _is_empty(value) for value in values)


def _config_shape(xml_bytes: bytes) -> dict[str, int]:
    try:
        root = ElementTree.fromstring(xml_bytes)
    except ElementTree.ParseError as exc:
        raise BackupError(f"config.xml is not valid XML: {exc}") from exc

    tags = Counter()
    for element in root.iter():
        tag = element.tag.rsplit("}", 1)[-1] if isinstance(element.tag, str) else str(element.tag)
        tags[tag] += 1
    return dict(sorted(tags.items()))


def _validate_member_name(name: str) -> None:
    # ZIP names use POSIX separators. Reject absolute paths, traversal, and
    # Windows-style separators before any extraction or rewrite.
    if not name or name in {".", ".."} or "/" in name or "\\" in name:
        raise BackupError(f"unsafe ZIP member name: {name!r}")
    parts = Path(name).parts
    if ".." in parts:
        raise BackupError(f"unsafe ZIP member name: {name!r}")


@dataclass(frozen=True)
class MemberInfo:
    name: str
    compressed_size: int
    file_size: int
    sha256: str
    kind: str

    def as_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "compressed_size": self.compressed_size,
            "file_size": self.file_size,
            "sha256": self.sha256,
            "kind": self.kind,
        }


@dataclass(frozen=True)
class BackupSummary:
    member_count: int
    missing_files: tuple[str, ...]
    extra_files: tuple[str, ...]
    members: tuple[MemberInfo, ...]
    counts: dict[str, Any]
    feature_usage: dict[str, int]
    rule_keys: dict[str, list[str]]
    top_level_keys: dict[str, list[str]]
    config_shape: dict[str, int]

    def as_dict(self) -> dict[str, Any]:
        return {
            "member_count": self.member_count,
            "missing_files": list(self.missing_files),
            "extra_files": list(self.extra_files),
            "members": [member.as_dict() for member in self.members],
            "counts": self.counts,
            "feature_usage": self.feature_usage,
            "rule_keys": self.rule_keys,
            "top_level_keys": self.top_level_keys,
            "config_shape": self.config_shape,
        }


class BackupBundle:
    """An Android backup with parsed JSON and byte-preserved members."""

    def __init__(
        self,
        members: dict[str, bytes],
        parsed_json: dict[str, Any],
        source_path: Path | None = None,
    ) -> None:
        self.members = members
        self.parsed_json = parsed_json
        self.source_path = source_path

    @classmethod
    def load(cls, path: str | os.PathLike[str]) -> "BackupBundle":
        archive_path = Path(path)
        if not archive_path.is_file():
            raise BackupError(f"backup does not exist: {archive_path}")

        members: dict[str, bytes] = {}
        parsed_json: dict[str, Any] = {}
        try:
            with zipfile.ZipFile(archive_path, "r") as archive:
                for info in archive.infolist():
                    if info.is_dir():
                        continue
                    _validate_member_name(info.filename)
                    if info.filename in members:
                        raise BackupError(f"duplicate ZIP member: {info.filename}")
                    data = archive.read(info)
                    members[info.filename] = data
                    if info.filename in JSON_BACKUP_FILES:
                        try:
                            parsed_json[info.filename] = json.loads(data.decode("utf-8"))
                        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                            raise BackupError(
                                f"{info.filename} is not valid UTF-8 JSON: {exc}"
                            ) from exc
                    elif info.filename == "config.xml":
                        _config_shape(data)
        except zipfile.BadZipFile as exc:
            raise BackupError(f"invalid ZIP archive: {exc}") from exc
        except RuntimeError as exc:
            raise BackupError(f"unable to read ZIP archive: {exc}") from exc

        return cls(members, parsed_json, archive_path)

    @classmethod
    def load_from_members(cls, members: dict[str, bytes]) -> "BackupBundle":
        """Build a bundle from already validated member bytes."""

        copied = dict(members)
        parsed_json: dict[str, Any] = {}
        for name, data in copied.items():
            _validate_member_name(name)
            if name in JSON_BACKUP_FILES:
                try:
                    parsed_json[name] = json.loads(data.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                    raise BackupError(f"{name} is not valid UTF-8 JSON: {exc}") from exc
            elif name == "config.xml":
                _config_shape(data)
        return cls(copied, parsed_json)

    def summary(self) -> BackupSummary:
        names = set(self.members)
        missing = tuple(sorted(set(ANDROID_BACKUP_FILES) - names))
        extra = tuple(sorted(names - set(ANDROID_BACKUP_FILES)))

        infos: list[MemberInfo] = []
        # Compression sizes are only available from the original archive. For
        # modified/in-memory members, use the uncompressed length as a safe
        # approximation rather than losing structural information.
        compressed_sizes: dict[str, int] = {}
        if self.source_path and self.source_path.is_file():
            with zipfile.ZipFile(self.source_path, "r") as archive:
                compressed_sizes = {
                    info.filename: info.compress_size
                    for info in archive.infolist()
                    if not info.is_dir()
                }
        for name in sorted(self.members):
            data = self.members[name]
            if name in JSON_BACKUP_FILES:
                kind = "json"
            elif name == "config.xml":
                kind = "xml"
            else:
                kind = "opaque"
            infos.append(
                MemberInfo(
                    name=name,
                    compressed_size=compressed_sizes.get(name, len(data)),
                    file_size=len(data),
                    sha256=hashlib.sha256(data).hexdigest(),
                    kind=kind,
                )
            )

        sources = self.parsed_json.get("bookSource.json", [])
        books = self.parsed_json.get("bookshelf.json", [])
        groups = self.parsed_json.get("bookGroup.json", [])
        sources = sources if isinstance(sources, list) else []
        books = books if isinstance(books, list) else []
        groups = groups if isinstance(groups, list) else []

        source_types = Counter(str(source.get("bookSourceType")) for source in sources)
        book_types = Counter(str(book.get("type")) for book in books)
        counts: dict[str, Any] = {
            "book_sources": len(sources),
            "bookshelf_books": len(books),
            "book_groups": len(groups),
            "source_types": dict(sorted(source_types.items())),
            "bookshelf_types": dict(sorted(book_types.items())),
            "read_records": len(self.parsed_json.get("readRecord.json", []) or []),
            "read_record_details": len(self.parsed_json.get("readRecordDetail.json", []) or []),
            "read_record_sessions": len(self.parsed_json.get("readRecordSession.json", []) or []),
        }

        feature_usage = {
            "sources_with_explore_url": _count_nonempty(source.get("exploreUrl") for source in sources),
            "sources_with_main_js": _count_nonempty(source.get("mainJs") for source in sources),
            "sources_with_js_lib": _count_nonempty(source.get("jsLib") for source in sources),
            "sources_with_login_url": _count_nonempty(source.get("loginUrl") for source in sources),
            "sources_with_login_ui": _count_nonempty(source.get("loginUi") for source in sources),
            "sources_with_cookie_jar": sum(source.get("enabledCookieJar") is True for source in sources),
            "sources_with_header": _count_nonempty(source.get("header") for source in sources),
            "sources_with_book_info_init": _count_nonempty(
                (source.get("ruleBookInfo") or {}).get("init")
                if isinstance(source.get("ruleBookInfo"), dict)
                else None
                for source in sources
            ),
            "sources_with_content_web_js": _count_nonempty(
                (source.get("ruleContent") or {}).get("webJs")
                if isinstance(source.get("ruleContent"), dict)
                else None
                for source in sources
            ),
            "sources_with_content_replace": _count_nonempty(
                (source.get("ruleContent") or {}).get("replaceRegex")
                if isinstance(source.get("ruleContent"), dict)
                else None
                for source in sources
            ),
            "sources_with_content_next_url": _count_nonempty(
                (source.get("ruleContent") or {}).get("nextContentUrl")
                if isinstance(source.get("ruleContent"), dict)
                else None
                for source in sources
            ),
            "sources_with_toc_next_url": _count_nonempty(
                (source.get("ruleToc") or {}).get("nextTocUrl")
                if isinstance(source.get("ruleToc"), dict)
                else None
                for source in sources
            ),
            "books_with_read_config": _count_nonempty(book.get("readConfig") for book in books),
            "books_with_variable": _count_nonempty(book.get("variable") for book in books),
        }

        rule_keys = {
            field: _rule_keys(sources, field)
            for field in ("ruleBookInfo", "ruleContent", "ruleExplore", "ruleSearch", "ruleToc")
        }
        top_level_keys = {
            filename: _union_object_keys(value)
            for filename, value in self.parsed_json.items()
        }
        config_shape = _config_shape(self.members["config.xml"]) if "config.xml" in self.members else {}
        return BackupSummary(
            member_count=len(self.members),
            missing_files=missing,
            extra_files=extra,
            members=tuple(infos),
            counts=counts,
            feature_usage=feature_usage,
            rule_keys=rule_keys,
            top_level_keys=top_level_keys,
            config_shape=config_shape,
        )

    def json(self, filename: str) -> Any:
        if filename not in JSON_BACKUP_FILES:
            raise BackupError(f"not a parsed JSON backup member: {filename}")
        return self.parsed_json[filename]

    def replace_json(self, filename: str, value: Any) -> None:
        if filename not in JSON_BACKUP_FILES:
            raise BackupError(f"not a replaceable JSON backup member: {filename}")
        self.parsed_json[filename] = value
        self.members[filename] = json.dumps(
            value,
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")

    def write(self, path: str | os.PathLike[str]) -> None:
        output_path = Path(path)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary_name = tempfile.mkstemp(
            prefix=f".{output_path.name}.",
            suffix=".tmp",
            dir=output_path.parent,
        )
        os.close(fd)
        temporary_path = Path(temporary_name)
        try:
            with zipfile.ZipFile(
                temporary_path,
                "w",
                compression=zipfile.ZIP_DEFLATED,
                compresslevel=6,
            ) as archive:
                ordered_names = [name for name in ANDROID_BACKUP_FILES if name in self.members]
                ordered_names.extend(sorted(set(self.members) - set(ordered_names)))
                for name in ordered_names:
                    _validate_member_name(name)
                    archive.writestr(name, self.members[name])
            os.replace(temporary_path, output_path)
        except Exception:
            try:
                temporary_path.unlink(missing_ok=True)
            finally:
                raise
