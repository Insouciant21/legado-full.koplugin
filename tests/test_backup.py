from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from legado_kindle.backup import IMPORT_MEMBERS, BackupBundle, BackupError
from legado_kindle.state import StateDirectory, StateError, import_bundle


class BackupTests(unittest.TestCase):
    def make_archive(self, directory: Path, include_group: bool = True) -> Path:
        path = directory / "sample.zip"
        source = {
            "bookSourceType": 0,
            "bookSourceUrl": "https://example.invalid",
            "bookSourceName": "fixture",
            "exploreUrl": "/explore/{{page}}",
            "enabledCookieJar": True,
            "jsLib": "function helper() {}",
            "ruleBookInfo": {"name": "@css:h1@text"},
            "ruleContent": {
                "content": "@css:article@text",
                "nextContentUrl": "@css:a.next@href",
            },
            "ruleToc": {
                "chapterList": "@css:a",
                "nextTocUrl": "@css:a.next@href",
            },
        }
        members = {
            "bookSource.json": [source],
            "bookshelf.json": [
                {
                    "name": "fixture",
                    "author": "author",
                    "bookUrl": "https://example.invalid/book",
                    "origin": "https://example.invalid",
                    "durChapterIndex": 12,
                    "durChapterTitle": "chapter",
                    "durChapterTime": 123,
                    "group": 7,
                    "readConfig": {"fontSize": 99, "fontFace": "Droid Sans Mono"},
                }
            ],
            "bookGroup.json": [{"groupId": 7, "groupName": "fixture group"}],
            "readRecord.json": [
                {
                    "bookName": "fixture",
                    "bookAuthor": "author",
                    "lastRead": 123,
                    "readTime": 456,
                }
            ],
            "readRecordDetail.json": [
                {
                    "bookName": "fixture",
                    "bookAuthor": "author",
                    "date": "2026-01-01",
                    "lastReadTime": 123,
                    "readTime": 456,
                }
            ],
            "readRecordSession.json": [
                {
                    "bookName": "fixture",
                    "bookAuthor": "author",
                    "startTime": 100,
                    "endTime": 123,
                    "words": 4,
                }
            ],
        }
        ignored = {
            # Invalid ignored members must not break an import.
            "readConfig.json": b"not-json",
            "servers.json": b"opaque-server-state",
            "config.xml": b"not-xml",
            "future-setting.bin": b"future",
        }
        with zipfile.ZipFile(path, "w") as archive:
            for filename in IMPORT_MEMBERS:
                archive.writestr(
                    filename,
                    json.dumps(members[filename], ensure_ascii=False).encode(),
                )
            for filename, data in ignored.items():
                archive.writestr(filename, data)
            if include_group:
                archive.writestr("bookGroup.json", b"not-json")
        return path

    def test_import_boundary_keeps_sources_records_and_strips_reader_config(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = BackupBundle.load(self.make_archive(Path(temporary)))
            self.assertEqual(tuple(bundle.members), IMPORT_MEMBERS)
            self.assertEqual(set(bundle.parsed_json), set(IMPORT_MEMBERS))
            self.assertIn("bookGroup.json", bundle.ignored_files)
            self.assertIn("readConfig.json", bundle.ignored_files)
            self.assertIn("config.xml", bundle.ignored_files)
            self.assertNotIn("readConfig", bundle.json("bookshelf.json")[0])
            self.assertNotIn("group", bundle.json("bookshelf.json")[0])
            self.assertEqual(len(bundle.json("readRecordSession.json")), 1)

    def test_archive_without_book_groups_is_valid(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = BackupBundle.load(
                self.make_archive(Path(temporary), include_group=False)
            )
            self.assertNotIn("bookGroup.json", bundle.members)
            self.assertEqual(tuple(bundle.members), IMPORT_MEMBERS)

    def test_summary_is_value_redacted_and_counts_rules_and_records(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = BackupBundle.load(self.make_archive(Path(temporary)))
            summary = archive.summary().as_dict()
            self.assertEqual(summary["counts"]["book_sources"], 1)
            self.assertEqual(summary["counts"]["bookshelf_books"], 1)
            self.assertEqual(summary["counts"]["read_records"], 1)
            self.assertEqual(summary["counts"]["read_record_details"], 1)
            self.assertEqual(summary["counts"]["read_record_sessions"], 1)
            self.assertEqual(summary["feature_usage"]["sources_with_js_lib"], 1)
            self.assertEqual(summary["feature_usage"]["sources_with_content_next_url"], 1)
            self.assertIn("nextContentUrl", summary["rule_keys"]["ruleContent"])
            rendered = str(summary)
            self.assertNotIn("https://example.invalid", rendered)
            self.assertNotIn("fixture", rendered)

    def test_missing_supported_member_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "incomplete.zip"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("bookSource.json", "[]")
            with self.assertRaisesRegex(BackupError, "bookSource|bookshelf"):
                BackupBundle.load(path)

    def test_zip_path_traversal_is_rejected_even_for_ignored_members(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "unsafe.zip"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("../escape.json", "{}")
            with self.assertRaises(BackupError):
                BackupBundle.load(path)

            nested = Path(temporary) / "nested.zip"
            with zipfile.ZipFile(nested, "w") as archive:
                archive.writestr("nested/member.json", "{}")
            with self.assertRaises(BackupError):
                BackupBundle.load(nested)

    def test_state_contains_only_import_members_and_preserves_progress_data(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = BackupBundle.load(self.make_archive(root))
            state = import_bundle(source, root / "state")
            self.assertIsInstance(state, StateDirectory)
            self.assertEqual(state.manifest()["state_schema_version"], 3)
            self.assertEqual(
                {child.name for child in state.root.iterdir()},
                set(IMPORT_MEMBERS) | {"manifest.json"},
            )
            self.assertFalse((state.root / "android").exists())
            self.assertFalse((state.root / "bookGroup.json").exists())
            self.assertNotIn("readConfig", json.loads(state.bookshelf_path.read_text()))
            self.assertNotIn("group", json.loads(state.bookshelf_path.read_text())[0])
            self.assertEqual(len(state.load_bundle().json("readRecord.json")), 1)

    def test_state_directory_rejects_tampered_member_and_android_settings(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = BackupBundle.load(self.make_archive(root))
            state = import_bundle(source, root / "state")
            (state.root / "readRecord.json").write_bytes(b"[]\n")
            with self.assertRaises(StateError):
                state.load_bundle()

            (state.root / "readConfig.json").write_bytes(b"[]")
            with self.assertRaises(StateError):
                state.load_bundle()

    def test_legacy_v2_state_is_read_without_book_groups(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            state = import_bundle(
                BackupBundle.load(self.make_archive(root)), root / "state"
            )
            manifest = state.manifest()
            manifest["state_schema_version"] = 2
            group_data = b"[{\"groupId\":7}]"
            (state.root / "bookGroup.json").write_bytes(group_data)
            manifest["members"].append(
                {"name": "bookGroup.json", "size": len(group_data), "kind": "json"}
            )
            state.manifest_path.write_text(
                json.dumps(manifest, ensure_ascii=False), encoding="utf-8"
            )
            loaded = state.load_bundle()
            self.assertEqual(tuple(loaded.members), IMPORT_MEMBERS)
            self.assertNotIn("bookGroup.json", loaded.members)


if __name__ == "__main__":
    unittest.main()
