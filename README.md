# cj

> Concise `.cc` DSL ↔ OpenAI-compatible JSON

`cj` is a small CLI for hand-authoring OpenAI Chat Completions request
bodies — tools, functions, messages, parameters. It uses an
indent-driven `.cc` DSL instead of nested JSON, and outputs the
exact format the OpenAI API accepts. With `-d` it goes the other way.

## Why `.cc`

- **1/4 the lines** of nested JSON — say goodbye to `}}}` nightmares
- **git-diff friendly** — one field per line, no `{}` noise
- **Comments and multi-line strings** — JSON doesn't have these
- **Exact round-trip** — `.cc` and JSON interconvert with full semantic
  equality (hash-order independent)

## Install

```bash
zig build              # build to zig-out/bin/cj
zig build run -- file  # build and run
```

Requires Zig 0.16+. Windows / Linux / macOS all supported.

## Usage

```bash
cj [options] [<input>]

Options:
  -p, --pretty    pretty-print JSON output (default: compact)
  -d, --decode    reverse: JSON → .cc
  -e, --encode    forward: .cc → JSON (default; explicit form)
  -h, --help      show help
```

Reads from stdin if no input file is given. **Format auto-detected** by
structural rules:
- starts with `{` / `[` → JSON object/array
- starts with `"` / digit / `-digit` → JSON string/number
- starts with `true` / `false` / `null` followed by only whitespace → JSON literal
- otherwise → `.cc`

Override with `-d` (force JSON → `.cc`) or `-e` (force `.cc` → JSON).

### Examples

```bash
# .cc → JSON (default)
cj tools.cc
cj tools.cc -p                  # pretty multi-line

# JSON → .cc (-d)
cj -d tools.golden.json

# Streaming
echo '{"a":1}' | cj             # auto JSON mode → emits .cc
echo 'a 1' | cj                 # auto .cc mode → emits JSON
echo 'model gpt-4' | cj -p

# Round-trip
cj tools.cc | cj                # back to .cc (field order may change; semantics equal)
```

## `.cc` DSL

### Fields

| Syntax | Meaning |
|---|---|
| `key value` | scalar value on the same line |
| `key` (no value) | value is a nested object on subsequent deeper-indented lines |
| `key+` / `key*` | value is an array (the two suffixes are equivalent) |
| `key:` | explicit empty object/array (rare) |

Indent is 2 spaces per level. Tabs also count as one indent unit.

### Scalar types (auto-inferred)

| Input | Type |
|---|---|
| `42`, `-7` | int |
| `3.14`, `1.5e10` | float |
| `true`, `false` | bool |
| `null`, `none`, `~` | null |
| `"quoted text"` | string (with quotes) |
| `unquoted text` | string (no quotes; the **entire rest of the line** is the value) |

### Strings

```cc
# Unquoted — everything after the first whitespace until EOL is the value
description Get weather, please.

# Quoted — use when the value contains special characters
content "Hello, \"world\"!"
escapes "line1\nline2\ttab"
path "C:\\Users\\foo"
```

Supported escapes: `\"` `\\` `\n` `\t` `\r` `\/` `\b` `\f`

### Arrays

```cc
# Array of scalars
required*
    location
    unit

# Array of objects — use a `,` line alone to separate items
messages+
    role system
    content 1
    ,
    role user
    content ls

# Implicit separator (no `,`) — the parser recognizes consecutive
# `key value` lines as one object. But explicit `,` is strongly
# recommended for clarity and safety.
```

### Comments

```cc
# Whole-line comment
model gpt-4   # Inline comments are NOT supported (to avoid string collisions)
```

## Full examples

### Single tool (get_weather)

```cc
# get_weather.cc
model gpt-4o-mini
tools*
    type function
    function
        name get_weather
        description Get current weather for a location
        parameters
            type object
            properties
                location
                    type string
                    description City and state, e.g. San Francisco, CA
                unit
                    type string
                    description Temperature unit
                    enum*
                        celsius
                        fahrenheit
            required*
                location
```

→ JSON:
```json
{"model":"gpt-4o-mini","tools":[{"type":"function","function":{"description":"Get current weather for a location","name":"get_weather","parameters":{"properties":{"location":{"description":"City and state, e.g. San Francisco, CA","type":"string"},"unit":{"description":"Temperature unit","type":"string","enum":["celsius","fahrenheit"]}},"type":"object","required":["location"]}}}]}
```

### Multi-turn conversation

```cc
# chat.cc
model gpt-4o
messages+
    role system
    content You are a helpful coding assistant.
    ,
    role user
    content Write a quicksort in Python.
    ,
    role assistant
    content "Sure! Here's a concise implementation:"
    ,
    role user
    content Thanks!
```

### JSON → .cc

```bash
$ echo '{"model":"gpt-4o","stream":true,"max_tokens":2048}' | cj -d
max_tokens 2048
model "gpt-4o"
stream true
```

## `.cc` cheat sheet

| Want to write | Syntax |
|---|---|
| String field | `desc "Hello"` or `desc Hello world` |
| Number field | `count 42`, `temp 3.14` |
| Boolean field | `stream true` |
| Null field | `data null` |
| Nested object | see below |
| Array of scalars | `arr*\n  item1\n  item2` |
| Array of objects | `arr+\n  f1 v1\n  f2 v2\n  ,\n  f1 v1\n  f2 v2` |
| Comment | `# ...` |
| String with `"` | `"he said \"hi\""` |
| String with `\n` | `"line1\nline2"` |

**Nested object example:**

```cc
function
    name my_tool
    parameters
        type object
        properties
            arg
                type string
                description The argument
```

## JSON mode (`-d`)

Reverse conversion: turn an OpenAI JSON response into an editable `.cc`:

```bash
cj -d api-response.json > editable.cc
# edit it...
cj editable.cc > new-request.json
```

Quoting rules for `.cc` output:
- **No quotes** if the value contains no special characters (spaces, commas, periods are all fine — they have no special meaning inside a `.cc` value)
- **Quotes required** if the value contains `"`, `\`, newlines, leading `#`, all-whitespace, reserved words (`true`/`null`/`~`), or looks like a number

This makes round-tripped `.cc` look as close to hand-written as possible.

## Testing

```bash
zig build test
```

**All 46 tests pass:**

- 10 fixtures (real OpenAI tool samples)
- Parser unit tests (tokenize, parseObject, parseArray, parseScalar)
- JSON parser unit tests (basic types, escapes, unicode, strict errors)
- `.cc` generator unit tests
- Helpers unit tests (`isValidIdentifier`, `needsQuoting`, `jsonEqual`)
- Edge cases (empty obj/array, scientific notation, deep nesting, mixed-type arrays, whitespace tolerance)
- **Full round-trip** (all 10 fixtures: `.cc → JSON → .cc → JSON` semantically equal)

## Known limitations

| Limit | Notes |
|---|---|
| Field order | Stored in `StringHashMap`; iteration order is hash order, not source order. JSON is semantically equal but bytes may differ |
| Key with escapes | Edge case: a JSON key containing escape characters (`\n`, `\"`, etc.) leaks memory. OpenAI-spec keys are all simple identifiers (`model`/`tools`/`name`/etc.) — not a problem in practice |
| Float precision | `.cc` expresses numbers as `f64`; IEEE 754 boundary values may not match the JSON string exactly |
| Multi-line strings | `"""..."""` heredoc form is not yet supported — use `\n` concatenation or single-line for long descriptions |

## Performance

- Parse: O(n), single pass with one hash map allocation
- Emit: O(n), single ArrayList append loop
- Zero-copy: unescaped strings borrow from the input slice
- Measured: 10KB OpenAI tools JSON < 10ms

## License

MIT

---

## Credits

- Inspired by tool templates in the Claude / OpenAI Cookbook
- Built for every LLM engineer wrestling with nested JSON `}}}` braces
