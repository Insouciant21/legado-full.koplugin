"""A dependency-free reference evaluator for common Legado source rules.

The Kindle implementation will use the same capability boundaries in Lua.  A
small Python evaluator is useful for fixtures and source compatibility checks
without requiring Android, a browser, or network access during development.
It intentionally refuses JavaScript and XPath instead of pretending that a
partial implementation is compatible.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from html import escape as html_escape
from html import unescape
from html.parser import HTMLParser
import json
import re
from typing import Any, Iterable, Mapping


class RuleError(ValueError):
    """Base class for rule parsing/evaluation failures."""


class UnsupportedRule(RuleError):
    """Raised when a rule needs a runtime capability not in this layer."""


@dataclass
class RuleContext:
    """Values available while expanding a source URL or rule template."""

    key: str = ""
    page: int = 1
    base_url: str = ""
    result: str = ""
    variables: dict[str, Any] = field(default_factory=dict)

    def values(self) -> dict[str, Any]:
        values: dict[str, Any] = {
            "key": self.key,
            "page": self.page,
            "baseUrl": self.base_url,
            "result": self.result,
        }
        values.update(self.variables)
        return values


@dataclass
class _Element:
    tag: str
    attrs: dict[str, str]
    parent: "_Element | None" = None
    children: list["_Element | str"] = field(default_factory=list)

    def elements(self) -> Iterable["_Element"]:
        for child in self.children:
            if isinstance(child, _Element):
                yield child
                yield from child.elements()

    def text(self) -> str:
        parts: list[str] = []
        for child in self.children:
            if isinstance(child, _Element):
                parts.append(child.text())
            else:
                parts.append(child)
        return _normalize_text("".join(parts))

    def own_text(self) -> str:
        return _normalize_text("".join(child for child in self.children if isinstance(child, str)))

    def inner_html(self) -> str:
        return "".join(_serialize(child) for child in self.children)

    def outer_html(self) -> str:
        return _serialize(self)


def _normalize_text(value: str) -> str:
    return re.sub(r"\s+", " ", unescape(value)).strip()


def _serialize(node: _Element | str) -> str:
    if isinstance(node, str):
        return html_escape(node, quote=False)
    attrs = "".join(
        f' {key}="{html_escape(value, quote=True)}"' for key, value in node.attrs.items()
    )
    if node.tag in {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}:
        return f"<{node.tag}{attrs}>"
    return f"<{node.tag}{attrs}>{node.inner_html()}</{node.tag}>"


class _DocumentParser(HTMLParser):
    _void_tags = {
        "area",
        "base",
        "br",
        "col",
        "embed",
        "hr",
        "img",
        "input",
        "link",
        "meta",
        "param",
        "source",
        "track",
        "wbr",
    }

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.root = _Element("root", {})
        self.stack = [self.root]

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        element = _Element(
            tag.lower(),
            {key.lower(): value or "" for key, value in attrs},
            self.stack[-1],
        )
        self.stack[-1].children.append(element)
        if element.tag not in self._void_tags:
            self.stack.append(element)

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.handle_starttag(tag, attrs)
        if self.stack[-1].tag == tag.lower():
            self.stack.pop()

    def handle_endtag(self, tag: str) -> None:
        normalized = tag.lower()
        for index in range(len(self.stack) - 1, 0, -1):
            if self.stack[index].tag == normalized:
                del self.stack[index:]
                return

    def handle_data(self, data: str) -> None:
        self.stack[-1].children.append(data)


def _parse_html(value: str) -> _Element:
    parser = _DocumentParser()
    parser.feed(value)
    parser.close()
    return parser.root


def _root_for(value: str | _Element) -> _Element:
    return value if isinstance(value, _Element) else _parse_html(str(value))


def _split_css_groups(selector: str) -> list[str]:
    groups: list[str] = []
    start = 0
    bracket = 0
    paren = 0
    quote = ""
    escaped = False
    for index, char in enumerate(selector):
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if quote:
            if char == quote:
                quote = ""
            continue
        if char in "'\"":
            quote = char
        elif char == "[":
            bracket += 1
        elif char == "]":
            bracket = max(0, bracket - 1)
        elif char == "(":
            paren += 1
        elif char == ")":
            paren = max(0, paren - 1)
        elif char == "," and bracket == 0 and paren == 0:
            groups.append(selector[start:index].strip())
            start = index + 1
    groups.append(selector[start:].strip())
    return [group for group in groups if group]


def _split_css_chain(selector: str) -> list[tuple[str, str | None]]:
    """Return simple selectors with the relation to the previous selector."""

    parts: list[tuple[str, str | None]] = []
    buffer: list[str] = []
    bracket = 0
    paren = 0
    quote = ""
    pending_space = False
    pending_relation: str | None = None

    def flush() -> None:
        nonlocal pending_space, pending_relation
        token = "".join(buffer).strip()
        buffer.clear()
        if not token:
            return
        relation = pending_relation
        if relation is None and parts and pending_space:
            relation = " "
        parts.append((token, relation))
        pending_space = False
        pending_relation = None

    for char in selector:
        if quote:
            buffer.append(char)
            if char == quote:
                quote = ""
            continue
        if char in "'\"":
            quote = char
            buffer.append(char)
        elif char == "[":
            bracket += 1
            buffer.append(char)
        elif char == "]":
            bracket = max(0, bracket - 1)
            buffer.append(char)
        elif char == "(":
            paren += 1
            buffer.append(char)
        elif char == ")":
            paren = max(0, paren - 1)
            buffer.append(char)
        elif bracket == 0 and paren == 0 and char == ">":
            flush()
            pending_relation = ">"
            pending_space = False
        elif bracket == 0 and paren == 0 and char.isspace():
            if buffer:
                flush()
            pending_space = True
        else:
            buffer.append(char)
    flush()
    return parts


def _unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        return value[1:-1]
    return value


def _parse_attribute(expression: str) -> tuple[str, str | None, str | None]:
    match = re.fullmatch(r"\s*([\w:-]+)\s*(?:(\!=|\*=|\^=|\$=|~=|\|=|=)\s*(.*))?", expression)
    if not match:
        raise RuleError(f"unsupported CSS attribute selector: [{expression}]")
    return match.group(1).lower(), match.group(2), _unquote(match.group(3) or "")


def _parse_simple_selector(selector: str) -> tuple[str, list[tuple[str, Any]]]:
    index = 0
    tag_match = re.match(r"^[\w*-]+", selector)
    tag = tag_match.group(0).lower() if tag_match else "*"
    if tag_match:
        index = tag_match.end()
    tests: list[tuple[str, Any]] = []
    while index < len(selector):
        marker = selector[index]
        if marker in ".#":
            match = re.match(r"[.#]([\w-]+)", selector[index:])
            if not match:
                raise RuleError(f"unsupported CSS selector: {selector}")
            tests.append(("class" if marker == "." else "id", match.group(1)))
            index += match.end()
        elif marker == "[":
            end = index + 1
            quote = ""
            while end < len(selector):
                char = selector[end]
                if quote:
                    if char == quote and selector[end - 1] != "\\":
                        quote = ""
                elif char in "'\"":
                    quote = char
                elif char == "]":
                    break
                end += 1
            if end >= len(selector):
                raise RuleError(f"unclosed CSS attribute selector: {selector}")
            tests.append(("attr", _parse_attribute(selector[index + 1 : end])))
            index = end + 1
        elif marker == ":":
            match = re.match(r":([\w-]+)", selector[index:])
            if not match:
                raise RuleError(f"unsupported CSS pseudo selector: {selector}")
            name = match.group(1).lower()
            index += match.end()
            argument = None
            if index < len(selector) and selector[index] == "(":
                depth = 1
                end = index + 1
                quote = ""
                while end < len(selector) and depth:
                    char = selector[end]
                    if quote:
                        if char == quote and selector[end - 1] != "\\":
                            quote = ""
                    elif char in "'\"":
                        quote = char
                    elif char == "(":
                        depth += 1
                    elif char == ")":
                        depth -= 1
                    end += 1
                if depth:
                    raise RuleError(f"unclosed CSS pseudo selector: {selector}")
                argument = selector[index + 1 : end - 1]
                index = end
            if name not in {"not", "first-child", "last-child", "nth-child", "contains"}:
                raise UnsupportedRule(f"CSS pseudo selector :{name}")
            tests.append(("pseudo", (name, argument)))
        else:
            raise RuleError(f"unsupported CSS selector near: {selector[index:]}")
    return tag, tests


def _element_siblings(element: _Element) -> list[_Element]:
    if not element.parent:
        return []
    return [child for child in element.parent.children if isinstance(child, _Element)]


def _matches_simple(element: _Element, selector: str) -> bool:
    tag, tests = _parse_simple_selector(selector)
    if tag != "*" and element.tag != tag:
        return False
    for kind, value in tests:
        if kind == "id" and element.attrs.get("id") != value:
            return False
        if kind == "class" and value not in element.attrs.get("class", "").split():
            return False
        if kind == "attr":
            name, operator, expected = value
            actual = element.attrs.get(name)
            if operator is None and actual is None:
                return False
            if operator is None:
                continue
            if actual is None:
                return False
            if operator == "=" and actual != expected:
                return False
            if operator == "!=" and actual == expected:
                return False
            if operator == "*=" and expected not in actual:
                return False
            if operator == "^=" and not actual.startswith(expected):
                return False
            if operator == "$=" and not actual.endswith(expected):
                return False
            if operator == "~=" and expected not in actual.split():
                return False
            if operator == "|=" and actual not in {expected} and not actual.startswith(expected + "-"):
                return False
        if kind == "pseudo":
            name, argument = value
            siblings = _element_siblings(element)
            position = siblings.index(element) + 1 if element in siblings else 0
            if name == "not" and _matches_simple(element, argument or "*"):
                return False
            if name == "first-child" and position != 1:
                return False
            if name == "last-child" and position != len(siblings):
                return False
            if name == "nth-child":
                if not argument or not argument.strip().isdigit() or position != int(argument.strip()):
                    return False
            if name == "contains" and (argument or "") not in element.text():
                return False
    return True


def _matches_chain(element: _Element, chain: list[tuple[str, str | None]]) -> bool:
    if not chain or not _matches_simple(element, chain[-1][0]):
        return False
    current = element
    for index in range(len(chain) - 1, 0, -1):
        relation = chain[index][1] or " "
        selector = chain[index - 1][0]
        if relation == ">":
            if current.parent is None or current.parent.tag == "root" or not _matches_simple(current.parent, selector):
                return False
            current = current.parent
        else:
            parent = current.parent
            while parent is not None and parent.tag != "root" and not _matches_simple(parent, selector):
                parent = parent.parent
            if parent is None or parent.tag == "root":
                return False
            current = parent
    return True


def _select(root: _Element, selector: str) -> list[_Element]:
    result: list[_Element] = []
    seen: set[int] = set()
    for group in _split_css_groups(selector):
        chain = _split_css_chain(group)
        for element in root.elements():
            if _matches_chain(element, chain) and id(element) not in seen:
                seen.add(id(element))
                result.append(element)
    return result


def _children(element: _Element) -> list[_Element]:
    return [child for child in element.children if isinstance(child, _Element)]


def _parse_index_item(item: str) -> int | tuple[int | None, int | None, int]:
    """Parse one item from Legado's ``[...]`` selector suffix."""

    item = item.strip()
    if re.fullmatch(r"-?\d+", item):
        return int(item)
    parts = item.split(":")
    if len(parts) not in {2, 3} or not any(part.strip() for part in parts):
        raise ValueError(item)
    numbers: list[int | None] = []
    for part in parts:
        part = part.strip()
        if not part:
            numbers.append(None)
        elif re.fullmatch(r"-?\d+", part):
            numbers.append(int(part))
        else:
            raise ValueError(item)
    return numbers[0], numbers[1], numbers[2] if len(numbers) == 3 and numbers[2] is not None else 1


def _parse_legacy_selector(rule: str) -> tuple[str, str, list[int | tuple[int | None, int | None, int]]] | None:
    """Return ``(base selector, filter mode, index items)`` for old Legado syntax.

    ``None`` means that a trailing bracket is ordinary CSS, for example
    ``a[href]``.  The format mirrors ``AnalyzeByJSoup.ElementsSingle``.
    """

    value = rule.strip()
    if value.endswith("]"):
        start = value.rfind("[")
        if start >= 0:
            body = value[start + 1 : -1].strip()
            mode = "."
            if body.startswith("!"):
                mode = "!"
                body = body[1:].strip()
            if body:
                try:
                    items = [_parse_index_item(item) for item in body.split(",")]
                except ValueError:
                    pass
                else:
                    return value[:start].strip(), mode, items

    match = re.fullmatch(r"(.*?)([.!])(-?\d+(?::-?\d+)*)", value)
    if not match:
        return None
    base, mode, suffix = match.groups()
    numbers = [int(part) for part in suffix.split(":")]
    return base.strip(), mode, numbers


def _normalize_index(index: int, length: int) -> int | None:
    if 0 <= index < length:
        return index
    if index < 0 and length >= -index:
        return index + length
    return None


def _expand_index_item(
    item: int | tuple[int | None, int | None, int], length: int
) -> list[int]:
    if isinstance(item, int):
        index = _normalize_index(item, length)
        return [] if index is None else [index]

    start_value, end_value, step_value = item
    start = 0 if start_value is None else start_value
    if start < 0:
        start += length
    end = length - 1 if end_value is None else end_value
    if end < 0:
        end += length
    if (start < 0 and end < 0) or (start >= length and end >= length) or length == 0:
        return []
    start = min(max(start, 0), length - 1)
    end = min(max(end, 0), length - 1)
    if start == end or step_value >= length:
        return [start]
    step = step_value if step_value > 0 else step_value + length if -step_value < length else 1
    if step <= 0:
        step = 1
    if end >= start:
        return list(range(start, end + 1, step))
    return list(range(start, end - 1, -step))


def _apply_legacy_indexes(
    elements: list[_Element], mode: str, items: list[int | tuple[int | None, int | None, int]]
) -> list[_Element]:
    if not items:
        return elements
    selected: list[int] = []
    seen: set[int] = set()
    # The Android implementation parses the suffix backwards and then walks
    # it backwards again; this is equivalent to applying items in source order.
    for item in items:
        for index in _expand_index_item(item, len(elements)):
            if index not in seen:
                seen.add(index)
                selected.append(index)
    if mode == "!":
        excluded = set(selected)
        return [element for index, element in enumerate(elements) if index not in excluded]
    return [elements[index] for index in selected]


def _select_legacy(root: _Element, expression: str) -> list[_Element]:
    parsed = _parse_legacy_selector(expression)
    base = parsed[0] if parsed else expression.strip()
    mode = parsed[1] if parsed else " "
    items = parsed[2] if parsed else []

    if base in {"", "children"}:
        elements = _children(root)
    else:
        prefix, _, value = base.partition(".")
        if prefix == "class" and value:
            elements = [
                element
                for element in root.elements()
                if value in element.attrs.get("class", "").split()
            ]
        elif prefix == "tag" and value:
            elements = [element for element in root.elements() if element.tag == value.lower()]
        elif prefix == "id" and value:
            elements = [element for element in root.elements() if element.attrs.get("id") == value]
        elif prefix == "text" and value:
            elements = [element for element in root.elements() if value in element.own_text()]
        else:
            elements = _select(root, base)
    return _apply_legacy_indexes(elements, mode, items)


def _split_top_level(value: str, operators: tuple[str, ...]) -> tuple[list[str], str | None]:
    parts: list[str] = []
    start = 0
    bracket = 0
    paren = 0
    brace = 0
    quote = ""
    escaped = False
    found: str | None = None
    index = 0
    while index < len(value):
        char = value[index]
        if escaped:
            escaped = False
            index += 1
            continue
        if char == "\\":
            escaped = True
            index += 1
            continue
        if quote:
            if char == quote:
                quote = ""
            index += 1
            continue
        if char in "'\"":
            quote = char
            index += 1
            continue
        if char == "[":
            bracket += 1
        elif char == "]":
            bracket = max(0, bracket - 1)
        elif char == "(":
            paren += 1
        elif char == ")":
            paren = max(0, paren - 1)
        elif char == "{":
            brace += 1
        elif char == "}":
            brace = max(0, brace - 1)
        if bracket == 0 and paren == 0 and brace == 0:
            match = next((operator for operator in operators if value.startswith(operator, index)), None)
            if match:
                if not found:
                    found = match
                if match == found:
                    parts.append(value[start:index])
                    start = index + len(match)
                    index = start
                    continue
        index += 1
    def clean_part(part: str) -> str:
        stripped = part.strip()
        # Whitespace after @text: is data, not rule syntax.  Keep it while
        # still allowing indentation around the rule itself.
        if stripped.lower().startswith("@text:"):
            leading = len(part) - len(part.lstrip())
            return part[leading:]
        return stripped

    if found is None:
        return [clean_part(value)], None
    parts = [clean_part(part) for part in parts]
    parts.append(clean_part(value[start:]))
    return parts, found


def _expand_template(expression: str, context: RuleContext) -> str:
    values = context.values()
    expression = expression.strip()
    if expression in values:
        return str(values[expression])
    root_name, _, path = expression.partition(".")
    if root_name in values and path:
        current: Any = values[root_name]
        for token in re.findall(r"[^.\[\]]+", path):
            if isinstance(current, list) and token.isdigit():
                index = int(token)
                current = current[index] if index < len(current) else None
            elif isinstance(current, dict):
                current = current.get(token)
            else:
                current = None
            if current is None:
                break
        if current is not None:
            return _stringify_json(current)
    arithmetic = re.fullmatch(r"(page)\s*([+-])\s*(\d+)", expression)
    if arithmetic:
        amount = int(arithmetic.group(3))
        return str(context.page + amount if arithmetic.group(2) == "+" else context.page - amount)
    string_literal = re.fullmatch(r"(['\"])(.*?)\1", expression, re.DOTALL)
    if string_literal:
        return string_literal.group(2)
    raise UnsupportedRule(f"template expression requires JavaScript: {expression}")


def expand_templates(value: str, context: RuleContext) -> str:
    def replace(match: re.Match[str]) -> str:
        return _expand_template(match.group(1), context)

    return re.sub(r"\{\{(.*?)\}\}", replace, value, flags=re.DOTALL)


def _replacement_for_python(value: str) -> str:
    value = value.replace("$$", "\0")
    value = re.sub(r"\$(\d+)", r"\\g<\1>", value)
    value = value.replace("$&", r"\g<0>")
    return value.replace("\0", "$")


def _json_path(value: Any, path: str) -> list[Any]:
    path = path.strip()
    if path.startswith("@json:"):
        path = path[6:]
    if path.startswith("$"):
        path = path[1:]
    tokens: list[str | int] = []
    index = 0
    while index < len(path):
        if path[index] == ".":
            index += 1
            match = re.match(r"[\w-]+", path[index:])
            if not match:
                raise RuleError(f"invalid JSON path: {path}")
            tokens.append(match.group(0))
            index += match.end()
        elif path[index] == "[":
            end = path.find("]", index + 1)
            if end < 0:
                raise RuleError(f"invalid JSON path: {path}")
            token = path[index + 1 : end].strip()
            if token == "*":
                tokens.append("*")
            elif token.isdigit():
                tokens.append(int(token))
            else:
                tokens.append(_unquote(token))
            index = end + 1
        elif path[index].isspace():
            index += 1
        else:
            match = re.match(r"[\w-]+", path[index:])
            if not match:
                raise RuleError(f"invalid JSON path: {path}")
            tokens.append(match.group(0))
            index += match.end()
    current = [value]
    for token in tokens:
        next_values: list[Any] = []
        for item in current:
            if token == "*":
                if isinstance(item, list):
                    next_values.extend(item)
                elif isinstance(item, dict):
                    next_values.extend(item.values())
            elif isinstance(token, int):
                if isinstance(item, list) and token < len(item):
                    next_values.append(item[token])
            elif isinstance(item, dict) and token in item:
                next_values.append(item[token])
        current = next_values
    return current


def _stringify_json(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    if value is True:
        return "true"
    if value is False:
        return "false"
    if value is None:
        return ""
    return str(value)


class RuleEngine:
    """Evaluate the common, non-JS subset of Android Legado rules."""

    _value_modes = {"text", "ownText", "textNodes", "html", "all"}

    def parse_list(
        self,
        content: str | Any,
        rule: str,
        context: RuleContext | None = None,
    ) -> list[str]:
        context = context or RuleContext()
        if rule is None or not str(rule).strip():
            return []
        if not isinstance(content, str):
            source = content
        else:
            source = content
        return self._evaluate(source, str(rule), context)

    def parse_text(
        self,
        content: str | Any,
        rule: str,
        context: RuleContext | None = None,
    ) -> str:
        return "\n".join(self.parse_list(content, rule, context))

    def elements(
        self,
        content: str | Any,
        rule: str,
        context: RuleContext | None = None,
    ) -> list[Any]:
        """Return HTML elements or JSON objects selected by a list rule."""

        context = context or RuleContext()
        template_context = context
        json_content: Any | None = None
        if isinstance(content, (dict, list)):
            json_content = content
        elif isinstance(content, str) and content.lstrip().startswith(("{", "[")):
            try:
                json_content = json.loads(content)
            except json.JSONDecodeError:
                json_content = None
        if json_content is not None:
            template_context = RuleContext(
                key=context.key,
                page=context.page,
                base_url=context.base_url,
                result=context.result,
                variables={**context.variables, "$": json_content},
            )
        expanded_rule = expand_templates(str(rule), template_context)
        replacement_parts, _ = _split_top_level(expanded_rule, ("##",))
        base_rule = replacement_parts[0]
        lowered = base_rule.lower()
        if lowered.startswith(("<js>", "@js:", "@webjs:")):
            raise UnsupportedRule("JavaScript source rule")
        if lowered.startswith("@xpath:") or base_rule.startswith("//"):
            raise UnsupportedRule("XPath source rule")
        if lowered.startswith("@json:") or base_rule.startswith("$"):
            value = content if not isinstance(content, str) else json.loads(content)
            return _json_path(value, base_rule)
        root = _root_for(content)
        if lowered.startswith("@css:"):
            selector, _ = self._selector_and_mode(base_rule[5:])
            return _select(root, selector)
        if base_rule.startswith("@@"):
            base_rule = base_rule[2:]
        pieces = [piece.strip() for piece in base_rule.split("@")] if "@" in base_rule else [base_rule]
        current: list[_Element] = [root]
        for selector in pieces:
            next_elements: list[_Element] = []
            for element in current:
                next_elements.extend(_select_legacy(element, selector))
            current = next_elements
        return current

    def apply_text_rule(
        self,
        content: str,
        rule: str,
        context: RuleContext | None = None,
    ) -> str:
        """Apply a ContentRule ``replaceRegex`` expression to plain text.

        Legado stores this field as another AnalyzeRule expression.  The most
        common form is ``##match##replacement`` (the empty first component
        means that the current text is the input).  A non-empty first
        component is also accepted and is evaluated before replacement.  The
        Android implementation trims every line before this whole-content
        pass, so the reference engine does the same.
        """

        context = context or RuleContext()
        raw_rule = str(rule or "")
        if not raw_rule.strip():
            return str(content or "")
        lowered = raw_rule.lstrip().lower()
        if lowered.startswith(("<js>", "@js:", "@webjs:")):
            raise UnsupportedRule("whole-content replacement uses JavaScript")

        expanded_rule = expand_templates(raw_rule, context)
        parts, _ = _split_top_level(expanded_rule, ("##",))
        base_rule = parts[0]
        normalized = "\n".join(
            line.strip()
            for line in str(content or "").replace("\r\n", "\n").replace("\r", "\n").split("\n")
        )
        if base_rule:
            target = self.parse_text(normalized, base_rule, context)
        else:
            target = normalized
        if len(parts) == 1:
            return target

        pattern = parts[1]
        replacement = parts[2] if len(parts) >= 3 else ""
        try:
            compiled = re.compile(pattern)
        except re.error as exc:
            raise RuleError(f"invalid whole-content replacement regex: {pattern}: {exc}") from exc
        count = 1 if len(parts) >= 4 else 0
        if count and compiled.search(target) is None:
            # Match AnalyzeRule's replaceFirst fallback for a compiled regex.
            return ""
        return compiled.sub(_replacement_for_python(replacement), target, count=count)

    def _evaluate(self, content: str | Any, rule: str, context: RuleContext) -> list[str]:
        parts, operator = _split_top_level(rule, ("||", "&&", "%%"))
        if operator is not None and len(parts) > 1:
            values = [self._evaluate(content, part, context) for part in parts]
            if operator == "||":
                return next((result for result in values if result), [])
            if operator == "%%":
                result: list[str] = []
                width = max((len(value) for value in values), default=0)
                for index in range(width):
                    for value in values:
                        if index < len(value):
                            result.append(value[index])
                return result
            return ["".join(value for result in values for value in result)]

        replacement_parts, _ = _split_top_level(rule, ("##",))
        base_rule = replacement_parts[0]
        template_context = context
        json_content: Any | None = None
        if isinstance(content, (dict, list)):
            json_content = content
        elif isinstance(content, str) and content.lstrip().startswith(("{", "[")):
            try:
                json_content = json.loads(content)
            except json.JSONDecodeError:
                json_content = None
        if json_content is not None:
            template_context = RuleContext(
                key=context.key,
                page=context.page,
                base_url=context.base_url,
                result=context.result,
                variables={**context.variables, "$": json_content},
            )
        base_rule = expand_templates(base_rule, template_context)
        values = self._evaluate_single(content, base_rule, context)
        if len(replacement_parts) > 1:
            pattern = replacement_parts[1]
            replacement = replacement_parts[2] if len(replacement_parts) >= 3 else ""
            count = 1 if len(replacement_parts) >= 4 else 0
            try:
                compiled = re.compile(pattern)
            except re.error as exc:
                raise RuleError(f"invalid replacement regex: {pattern}: {exc}") from exc
            values = [compiled.sub(_replacement_for_python(replacement), value, count=count) for value in values]
        return [value for value in values if value != ""]

    def _evaluate_single(self, content: str | Any, rule: str, context: RuleContext) -> list[str]:
        lowered = rule.lower()
        if lowered.startswith("<js>") or lowered.startswith("@js:") or lowered.startswith("@webjs:"):
            raise UnsupportedRule("JavaScript source rule")
        if lowered.startswith("@xpath:") or (rule.startswith("/") and not rule.startswith("//")):
            raise UnsupportedRule("XPath source rule")
        if lowered.startswith("@text:"):
            leading = len(rule) - len(rule.lstrip())
            return [rule[leading + 6 :]]
        if lowered.startswith("@regex:"):
            return self._regex_values(str(content), rule[7:])
        if lowered.startswith("@json:") or rule.startswith("$"):
            value = content if not isinstance(content, str) else json.loads(content)
            return [_stringify_json(item) for item in _json_path(value, rule)]
        if lowered.startswith("@css:"):
            return self._css_values(content, rule[5:])
        if rule.startswith("@@"):
            return self._css_values(content, rule[2:])
        if isinstance(content, (dict, list)):
            return [_stringify_json(item) for item in _json_path(content, rule)]
        return self._default_values(content, rule)

    def _regex_values(self, content: str, expression: str) -> list[str]:
        try:
            matches = list(re.finditer(expression, content, flags=re.DOTALL))
        except re.error as exc:
            raise RuleError(f"invalid source regex: {expression}: {exc}") from exc
        if not matches:
            return []
        if matches[0].lastindex:
            return [match.group(1) or "" for match in matches]
        return [match.group(0) for match in matches]

    def _css_values(self, content: str | _Element, expression: str) -> list[str]:
        selector, mode = self._selector_and_mode(expression)
        root = _root_for(content)
        elements = _select(root, selector)
        return [self._element_value(element, mode) for element in elements]

    def _default_values(self, content: str | _Element, expression: str) -> list[str]:
        pieces = [piece.strip() for piece in expression.split("@")] if "@" in expression else [expression]
        root = _root_for(content)
        current = [root]
        for selector in pieces[:-1]:
            next_elements: list[_Element] = []
            for element in current:
                next_elements.extend(_select_legacy(element, selector))
            current = next_elements
        mode = pieces[-1] if len(pieces) > 1 else "text"
        if len(pieces) == 1:
            current = _select_legacy(root, pieces[0])
        return [self._element_value(element, mode) for element in current]

    def _selector_and_mode(self, expression: str) -> tuple[str, str]:
        if "@" not in expression:
            return expression.strip(), "text"
        selector, mode = expression.rsplit("@", 1)
        return selector.strip(), mode.strip() or "text"

    def _element_value(self, element: _Element, mode: str) -> str:
        if mode == "text":
            return element.text()
        if mode == "ownText":
            return element.own_text()
        if mode == "textNodes":
            return "\n".join(
                _normalize_text(child) for child in element.children if isinstance(child, str) and _normalize_text(child)
            )
        if mode == "html":
            return element.inner_html()
        if mode == "all":
            return element.outer_html()
        return element.attrs.get(mode, "")


def _walk_strings(value: Any) -> Iterable[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, Mapping):
        for child in value.values():
            yield from _walk_strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from _walk_strings(child)


@dataclass(frozen=True)
class SourceDefinition:
    """A non-mutating view of one Android ``bookSource.json`` object."""

    raw: Mapping[str, Any]

    @classmethod
    def from_mapping(cls, value: Mapping[str, Any]) -> "SourceDefinition":
        return cls(value)

    @property
    def name(self) -> str:
        return str(self.raw.get("bookSourceName") or "")

    @property
    def url(self) -> str:
        return str(self.raw.get("bookSourceUrl") or "")

    @property
    def source_type(self) -> int:
        try:
            return int(self.raw.get("bookSourceType", 0))
        except (TypeError, ValueError):
            return -1

    def compatibility_report(self) -> dict[str, Any]:
        strings = list(_walk_strings(self.raw))
        content_rule = self.raw.get("ruleContent")
        counts = {
            "css": sum("@css:" in value.lower() or value.startswith("@@") for value in strings),
            "json": sum("@json:" in value.lower() or value.startswith("$." ) for value in strings),
            "regex": sum("@regex:" in value.lower() or value.startswith(":") for value in strings),
            "replacements": int(
                isinstance(content_rule, Mapping)
                and bool(content_rule.get("replaceRegex"))
            ),
            # Keep this report conservative: protocol-relative URLs also start
            # with //, so unmarked XPath is handled at evaluation time but not
            # counted here unless it has the explicit marker.
            "xpath": sum("@xpath:" in value.lower() for value in strings),
            "javascript": sum(
                value.lower().startswith(("@js:", "@webjs:", "<js>")) or "java." in value
                for value in strings
            ),
            "templates": sum("{{" in value and "}}" in value for value in strings),
        }
        unsupported = []
        if counts["xpath"]:
            unsupported.append("xpath")
        if counts["javascript"]:
            unsupported.append("javascript")
        return {
            "text_source": self.source_type == 0,
            "counts": counts,
            "unsupported_capabilities": unsupported,
            "fully_supported_by_reference_engine": not unsupported,
        }


__all__ = [
    "RuleContext",
    "RuleEngine",
    "RuleError",
    "SourceDefinition",
    "UnsupportedRule",
    "expand_templates",
]
