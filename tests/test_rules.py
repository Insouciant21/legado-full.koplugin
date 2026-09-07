from __future__ import annotations

import unittest

from legado_kindle.rules import RuleContext, RuleEngine, SourceDefinition, UnsupportedRule


class RuleEngineTests(unittest.TestCase):
    def setUp(self) -> None:
        self.engine = RuleEngine()
        self.html = """
        <html><body>
          <div class='book'><h1> 书名 </h1><span class='author'>作者</span></div>
          <ul><li data-id='1'><a href='/one'>第一章</a></li>
              <li data-id='2'><a href='/two'>第二章</a></li></ul>
        </body></html>
        """

    def test_css_text_and_attribute(self) -> None:
        self.assertEqual(self.engine.parse_text(self.html, "@css:h1@text"), "书名")
        self.assertEqual(
            self.engine.parse_list(self.html, "@css:li > a@href"),
            ["/one", "/two"],
        )

    def test_composition_and_replacement(self) -> None:
        self.assertEqual(
            self.engine.parse_list(self.html, "@css:.missing@text || @css:h1@text"),
            ["书名"],
        )
        self.assertEqual(
            self.engine.parse_list(self.html, "@css:h1@text && @text: - && @css:.author@text"),
            ["书名 - 作者"],
        )
        self.assertEqual(
            self.engine.parse_list(self.html, "@css:li@data-id %% @css:li@text"),
            ["1", "第一章", "2", "第二章"],
        )
        self.assertEqual(
            self.engine.parse_list("<p>字数：12,345 字</p>", "@css:p@text##[^0-9]+##"),
            ["12345"],
        )

    def test_whole_content_replacement(self) -> None:
        self.assertEqual(
            self.engine.apply_text_rule("  广告  \n正文", "##广告##"),
            "\n正文",
        )
        self.assertEqual(
            self.engine.apply_text_rule("a12 b34", "##(\\d+)##[$1]"),
            "a[12] b[34]",
        )
        self.assertEqual(
            self.engine.apply_text_rule("前缀 书名 后缀", "##{{book.name}}##" , RuleContext(variables={"book": {"name": "书名"}})),
            "前缀  后缀",
        )

    def test_json_regex_and_template(self) -> None:
        value = '{"items":[{"name":"a"},{"name":"b"}]}'
        self.assertEqual(self.engine.parse_list(value, "@json:$.items[*].name"), ["a", "b"])
        self.assertEqual(self.engine.parse_list("id=123 id=456", "@regex:id=(\\d+)"), ["123", "456"])
        self.assertEqual(
            self.engine.parse_text("", "@text:page={{page}}", RuleContext(page=3)),
            "page=3",
        )
        context = RuleContext(variables={"book": {"name": "书"}})
        self.assertEqual(self.engine.parse_text("", "@text:{{book.name}}", context), "书")
        self.assertEqual(self.engine.parse_text('{"id":"x"}', "@text:{{$.id}}"), "x")

    def test_legacy_legado_selectors_and_indexes(self) -> None:
        self.assertEqual(self.engine.parse_list(self.html, "tag.li.0@text"), ["第一章"])
        self.assertEqual(self.engine.parse_list(self.html, "tag.li!0@text"), ["第二章"])
        self.assertEqual(self.engine.parse_list(self.html, "li[1]@text"), ["第二章"])
        self.assertEqual(
            self.engine.parse_list(self.html, "li[-1:0]@text"),
            ["第二章", "第一章"],
        )
        self.assertEqual(
            self.engine.parse_list(self.html, "ul@children[0]@text"),
            ["第一章"],
        )
        self.assertEqual(
            self.engine.parse_list(self.html, "li[data-id='1']@text"),
            ["第一章"],
        )
        selected = self.engine.elements(self.html, "ul@li[1]")
        self.assertEqual([element.text() for element in selected], ["第二章"])
        records = self.engine.elements('{"items":[{"name":"a"},{"name":"b"}]}', "@json:$.items[*]")
        self.assertEqual([record["name"] for record in records], ["a", "b"])

    def test_unsupported_capabilities_are_explicit(self) -> None:
        with self.assertRaises(UnsupportedRule):
            self.engine.parse_list(self.html, "@js:result")
        with self.assertRaises(UnsupportedRule):
            self.engine.parse_list(self.html, "@xpath://h1/text()")
        report = SourceDefinition.from_mapping(
            {
                "bookSourceType": 0,
                "bookSourceName": "fixture",
                "ruleContent": {"content": "@css:article@text"},
            }
        ).compatibility_report()
        self.assertTrue(report["text_source"])
        self.assertEqual(report["unsupported_capabilities"], [])
        self.assertEqual(report["counts"]["replacements"], 0)

        replacement_report = SourceDefinition.from_mapping(
            {
                "bookSourceType": 0,
                "ruleContent": {"replaceRegex": "##广告##"},
            }
        ).compatibility_report()
        self.assertEqual(replacement_report["counts"]["replacements"], 1)


if __name__ == "__main__":
    unittest.main()
