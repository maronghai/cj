# cj — The Complete Guide

> A practical book on the `.cc` ↔ JSON DSL for OpenAI tool definitions.

`cj` is a small command-line tool that converts between a hand-editable
`.cc` DSL and OpenAI's JSON format for Chat Completions (tools, functions,
messages, parameters). This book teaches you everything you need to use
it well.

---

## How to read this book

The book has five parts:

- **Part I — Getting Started** covers installation and your first
  conversions. Read it first.
- **Part II — The .cc DSL** is the language reference. Skim it, then
  come back when you need a specific feature.
- **Part III — OpenAI Cookbook** is worked examples for the patterns
  you'll actually use (single tools, enums, multi-turn, multi-tool).
- **Part IV — JSON Mode** covers `-d` (JSON → `.cc`) and round-trip
  workflows. Read this when you need to edit existing JSON.
- **Part V — Internals** explains how the parser and writer work. Read
  it if you want to extend cj or just understand its limits.

The appendices at the end are quick-reference tables.

Code blocks starting with `cj ...` are shell commands. Blocks starting
with `.cc` or `json` are the language being discussed.

---

# Part I — Getting Started

## 1. What is cj?

`cj` solves one specific problem: hand-writing OpenAI Chat Completions
request bodies. If you've ever tried to write a request with multiple
tool definitions, each with nested parameters, properties, required
fields, and enums, you know the JSON is enormous:

```json
{
  "model": "gpt-4o",
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get current weather for a location",
        "parameters": {
          "type": "object",
          "properties": {
            "location": {
              "type": "string",
              "description": "City and state, e.g. San Francisco, CA"
            }
          },
          "required": ["location"]
        }
      }
    }
  ]
}
```

This is 25 lines, with `{}` and `[]` everywhere. Editing it is painful,
diffing it in git is noisy, and there's no way to add comments.

`cj` gives you a better way to write the same thing:

```cc
# weather tool
model gpt-4o
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
            required*
                location
```

This is 14 lines, indented by 4 spaces per level. It's diff-friendly,
supports comments, and reads like a config file. `cj` converts it to the
exact same JSON that the OpenAI API expects.

`cj` also goes the other way: with `-d`, it takes an OpenAI JSON
response and produces an editable `.cc` file. This means you can:

1. Start with a request from the OpenAI Playground
2. Convert it to `.cc` with `cj -d`
3. Edit it (add tools, change parameters)
4. Convert back to JSON with `cj`
5. Send it to the API

That's the round-trip workflow, and it works.

### Who is this book for?

- **LLM application engineers** who maintain tool configs and want
  something better than nested JSON.
- **AI agent authors** who want to version-control their tool sets.
- **Anyone who's tired of writing `}}}`** in their sleep.

You should be comfortable with the command line and have used the
OpenAI API at least once. No prior knowledge of `.cc` is assumed.

### What cj is not

- **Not a schema validator.** `cj` doesn't check that your output is
  valid OpenAI JSON Schema. The OpenAI API will tell you if you got it
  wrong.
- **Not a request builder.** It doesn't add authentication, manage
  rate limits, or send the request anywhere. It just translates.
- **Not a JSON pretty-printer** (although it has `-p` for that).

If you want those, pair `cj` with `jq`, `curl`, or your favorite
HTTP client.

## 2. Installing cj

`cj` is a single binary written in Zig 0.16. Building it requires the
Zig compiler.

### Prerequisites

- **Zig 0.16 or newer.** Get it from
  [ziglang.org/download](https://ziglang.org/download/) or your package
  manager.
- A C compiler (Zig uses it for some libc functions on Linux/macOS).
  On Windows, Zig ships with one.
- About 5 MB of disk space.

### Building from source

```bash
git clone <repo-url> cj
cd cj
zig build
```

The binary lands in `zig-out/bin/cj` (or `cj.exe` on Windows).

### Verifying

```bash
$ ./zig-out/bin/cj --help
cj — convert between .cc tools DSL and OpenAI-compatible JSON

Usage:
  cj [options] [<input>]

Options:
  -p, --pretty    pretty-print JSON output (default: compact)
  -d, --decode    decode: read JSON, output .cc (default: read .cc, output JSON)
  -e, --encode    encode: read .cc, output JSON (default)
  -h, --help      show this help

Reads from stdin if no input file is given. Format is auto-detected
by structure: starts with {/[ = JSON object/array, with " or digit
= JSON primitive, with true/false/null (followed by only whitespace)
= JSON literal. Otherwise treated as .cc. Override with -d / -e.
```

If you see this, you're ready to go.

### Installing system-wide

```bash
zig build install --prefix ~/.local
# or, with sudo:
sudo zig build install --prefix /usr/local
```

Then `cj` is on your `$PATH`.

### Cross-compilation

Zig makes this easy:

```bash
# Windows from Linux
zig build -Dtarget=x86_64-windows

# macOS from Linux
zig build -Dtarget=aarch64-macos

# ARM Linux
zig build -Dtarget=aarch64-linux
```

The resulting binary is in `zig-out/bin/`.

## 3. Hello, .cc

Let's write your first `.cc` file. Open a text editor and create
`hello.cc`:

```cc
# My first cj request
model gpt-4o-mini
messages+
    role user
    content Hello, world!
```

This is a minimal OpenAI request: send "Hello, world!" to GPT-4o Mini
and get a response. Three top-level fields: `model`, `messages` (an
array, indicated by the `+` suffix), and inside the array, one message
object with `role` and `content`.

Now convert it to JSON:

```bash
$ cj hello.cc
{"model":"gpt-4o-mini","messages":[{"role":"user","content":"Hello, world!"}]}
```

That's it. The JSON is one line, ready to send to the OpenAI API.

### What just happened?

`cj` read the `.cc` file, parsed it into a tree, and serialized that
tree to JSON. Every `.cc` construct maps to a JSON construct:

| `.cc` | JSON |
|---|---|
| `key value` | `"key": "value"` (or scalar) |
| `key` (no value) + nested lines | `"key": { ... }` |
| `key+` or `key*` | `"key": [ ... ]` |
| `,` on its own line | array separator |

Indentation matters: 2 spaces per level (or 1 tab). `cj` doesn't care
which you use, just be consistent.

### Try it with `-p`

If you want a human-readable JSON for inspection, use `-p`:

```bash
$ cj hello.cc -p
{
  "model": "gpt-4o-mini",
  "messages": [
    {
      "role": "user",
      "content": "Hello, world!"
    }
  ]
}
```

Useful for debugging. Use the compact form (without `-p`) for API
calls.

## 4. Hello, JSON (in reverse)

Let's go the other way. Suppose you have an OpenAI request as JSON
(maybe copied from a Playground, or a saved conversation). You can
convert it to editable `.cc`:

```bash
$ echo '{"model":"gpt-4o","stream":true,"temperature":0.7}' | cj -d
model "gpt-4o"
stream true
temperature 0.7
```

That's it. `cj -d` reads the JSON, parses it, and writes the equivalent
`.cc`.

### Or save to a file

```bash
$ cj -d request.json > request.cc
$ cat request.cc
model "gpt-4"
tools*
  type "function"
  function
    name "my_tool"
    ...
```

Now you can edit `request.cc`, then convert back:

```bash
$ cj request.cc > new-request.json
```

That's the round-trip in two commands.

### Auto-detect: when you don't need `-d`

By default, `cj` looks at the input structure to decide the direction:

- Starts with `{` or `[` → it's JSON, decode to `.cc`
- Starts with `"`, a digit, or `-digit` → JSON primitive, decode
- Starts with `true`/`false`/`null` followed by only whitespace → JSON
  literal
- Otherwise → it's `.cc`, encode to JSON

So `echo 'model gpt-4' | cj` does the encode (no flag needed), and
`echo '{"a":1}' | cj` does the decode. This makes the round-trip
trivial:

```bash
$ cj hello.cc | cj
# Round-trips back to .cc
model "gpt-4o-mini"
messages*
  role "user"
  content "Hello, world!"
```

The field order may differ (see Chapter 18) but the data is identical.

If the auto-detect ever gets it wrong, use `-d` (force JSON → `.cc`) or
`-e` (force `.cc` → JSON) to override.

---

# Part II — The .cc DSL

This part is the language reference. Skim it once, then come back when
you need a specific feature.

## 5. Fields and indentation

A `.cc` file is a tree. The top level is an object (the OpenAI request
body). Every line is either a field, a separator, a comment, or empty.

### The basic field

A field has a name, optional whitespace, and an optional value:

```cc
name value
```

If the value is present, it's the rest of the line (after the first
whitespace). The value can be a scalar (number, string, bool, null) or
nothing at all.

If the value is absent, the value is whatever comes on the next lines,
at a deeper indent level. This is how nested objects work.

### Indentation

`cj` treats each level of indentation as 2 spaces (or 1 tab, but pick
one and stick with it). The top level is indent 0. Children are
indent 1 (2 spaces), grandchildren are indent 2 (4 spaces), and so on.

Here's a tree with indents marked:

```cc
# field at indent 0 (top level)
top_field value
    # field at indent 1 (child of top_field)
    child_field child_value
        # field at indent 2 (grandchild)
    grandchild_field grandchild_value
```

The values `child_value` and `grandchild_value` are scalars on the same
line. If you wanted them to be nested objects, you'd add deeper-indent
lines below them.

### An empty value

What if a field has a name but no value, and no nested content? It
becomes an empty string in the JSON:

```cc
empty_field
```

becomes `"empty_field": ""`.

This is rarely what you want, but it's valid.

### A field with a long value

If your value is a long sentence, just put it on the same line:

```cc
description Get the current weather for a location, including temperature, humidity, and wind speed.
```

The value is everything after `description ` (the first whitespace
delimiter). Commas, periods, and other punctuation are fine — they
have no special meaning in `.cc` values.

If the value has special characters (a literal quote, a backslash), use
quoted form (see Chapter 7).

### Nesting depth

There's no hard limit. `cj` handles arbitrary nesting. Real OpenAI
tools rarely go past 4 or 5 levels, but if you need more, just keep
indenting.

## 6. Scalar types

`cj` infers the type of each value automatically. You don't write
`type: string` or `int: 42` — the parser figures it out from the text.

### Numbers

Integers and floats:

```cc
count 42
ratio 0.75
temp -3.14
big 1.5e10
```

Numbers can have a leading sign, decimal point, and exponent. The
parser distinguishes int from float by the presence of `.` or `e`/`E`.

### Booleans

```cc
stream true
verbose false
```

### Null

Three ways to write null, all equivalent:

```cc
data null
data none
data ~
```

The `~` form is borrowed from TOML.

### Strings (unquoted)

If the value isn't a number, bool, null, or quoted string, it's an
unquoted string. The value is everything after the first whitespace
until the end of the line.

```cc
description Get the weather
city San Francisco
```

Unquoted strings can contain spaces, commas, periods, colons, dashes,
underscores — anything except characters that would confuse the
parser. See Chapter 7 for when you need to quote.

### Strings (quoted)

When your value contains a quote, backslash, or starts with a hash,
quote it:

```cc
content "He said \"hello\""
path "C:\\Users\\foo"
emoji "Hello, 世界"
```

Quoted strings are exactly JSON strings, with the same escape rules
(see Chapter 7). This means anything you can put in a JSON string can
go in a quoted `.cc` string.

### Reserved words

Be careful: `true`, `false`, `null`, `none`, `~` are special. If you
have a value that looks like one of these, quote it:

```cc
# This is the string "true", not the boolean
answer "true"
```

`cj` won't auto-quote these for you. If you write `answer true`, it
parses as the boolean `true`, not the string `"true"`.

## 7. Strings and escapes

`cj` supports two string forms: unquoted (rare special chars) and
quoted (full JSON escape support).

### Unquoted strings

An unquoted string is the rest of the line after the field name and
whitespace:

```cc
description Get the weather
```

Allowed in unquoted strings: letters, digits, spaces, tabs, commas,
periods, semicolons, colons, dashes, underscores, slashes, parentheses,
brackets, and most other printable ASCII.

Disallowed in unquoted strings (must quote instead):

- The quote character `"` (would end a quoted string)
- The backslash `\` (would be interpreted as an escape)
- A leading `#` (would be a comment)
- Newlines or carriage returns (would end the line)
- A field name that *starts* with `+` or `*` (would be an array suffix)

### Quoted strings

A quoted string is a JSON string literal. It starts and ends with `"`,
and inside it, the same escapes that work in JSON work here:

| Escape | Meaning |
|---|---|
| `\"` | literal `"` |
| `\\` | literal `\` |
| `\/` | literal `/` |
| `\n` | newline |
| `\t` | tab |
| `\r` | carriage return |
| `\b` | backspace |
| `\f` | form feed |
| `\uXXXX` | Unicode code point (BMP, no surrogate pairs) |

Examples:

```cc
# Literal quote
content "She said \"yes\""

# Newline and tab
content "line 1\nline 2\tindented"

# Unicode
emoji "Hello, 世界"  # "Hello, 世界"
```

### When to use which

Default to unquoted. It's cleaner and matches how you naturally write
English. Switch to quoted when:

- The value contains `"`, `\`, or starts with `#`
- The value needs `\n`, `\t`, or other escapes
- The value is empty (use `""`)
- The value is `true`, `false`, `null`, `none`, or `~` (otherwise it
  gets parsed as that type)
- The value looks like a number (`42`, `-7`, `3.14`)

For multi-line strings, use `\n` escapes within a quoted string:

```cc
content "First paragraph.\n\nSecond paragraph with details."
```

This becomes a JSON string with a real newline character in the
middle, which is what OpenAI's API expects.

## 8. Arrays

Arrays in `.cc` use a suffix on the field name: `+` or `*`. They
behave identically. (The two forms are equivalent; pick one and use it
consistently.)

### Array of scalars

```cc
required*
    location
    unit
```

becomes

```json
"required": ["location", "unit"]
```

Each item is on its own line, at one indent deeper than the field
name. Scalar items don't need quotes (unless the value has special
characters).

### Array of objects

Use a `,` line alone to separate items:

```cc
messages+
    role system
    content You are helpful.
    ,
    role user
    content Hello!
    ,
    role assistant
    content Hi there!
```

becomes

```json
"messages": [
  {"role": "system", "content": "You are helpful."},
  {"role": "user", "content": "Hello!"},
  {"role": "assistant", "content": "Hi there!"}
]
```

Each item is a `key value` block. The `,` between them is a separator.
You can omit the comma if all items are at the same indent and the
parser can figure it out, but explicit `,` is clearer and safer.

### Mixing scalars and objects

`cj` prefers one type per array. If your array mixes scalars and
objects, the output uses `,` only between objects, not between
scalars. But for clarity, keep arrays homogeneous.

### Empty arrays

```cc
optional_items*
```

becomes `"optional_items": []`. No items inside.

### Nested arrays

Arrays can contain arrays. Each level uses the `+`/`*` suffix:

```cc
matrix*
    +
        1
        2
    ,
    +
        3
        4
```

This is uncommon for OpenAI tools but valid. The structure is
self-similar.

### How the parser decides: scalar or object?

When the parser sees an array item, it has to decide: is this item a
scalar (single value) or an object (multiple fields)?

The rule:

1. If the item has a value on its own line (`name value` or `name+`),
   it's an object.
2. If the item has no value, AND the next line is at a deeper indent,
   it's an object.
3. Otherwise, it's a scalar.

In practice, this means:

```cc
# All scalar items
arr*
    hello
    world
# → ["hello", "world"]

# All object items (with `,` separator)
arr*
    a 1
    b 2
    ,
    a 3
    b 4
# → [{"a": 1, "b": 2}, {"a": 3, "b": 4}]
```

If you're not sure, use `,` between items and explicit field names
inside each item. That always works.

## 9. Comments

`cj` supports whole-line comments with `#`:

```cc
# This is a comment
model gpt-4  # NOT a comment (no inline support)

# Multi-line comments are just multiple lines
# of comments. There's no block comment syntax.
```

A `#` at the start of a line (after indent) starts a comment. The
comment runs to the end of the line.

### Why no inline comments?

Inline comments (`field value  # comment`) are a common feature in
config formats. `cj` doesn't support them because they conflict with
string values:

```cc
# Is this description with inline comment?
description Some text # more text
```

The parser can't tell where the value ends. To avoid this ambiguity,
`cj` requires comments to be on their own line.

If you want to "comment out" a field, prefix the line with `#`:

```cc
# model gpt-4
debug true
```

The commented line is skipped entirely.

## 10. Putting it together

Let's write a non-trivial `.cc` file to see how all the pieces fit.

Here's a request for an AI assistant that can search the web:

```cc
# web-search agent
model gpt-4o
temperature 0.3
max_tokens 2000
stream true
tools*
    type function
    function
        name web_search
        description Search the web and return the top results
        parameters
            type object
            properties
                query
                    type string
                    description The search query
                num_results
                    type integer
                    description How many results to return (1-10)
                    minimum 1
                    maximum 10
                recency
                    type string
                    description Filter by time
                    enum*
                        day
                        week
                        month
                        any
            required*
                query
```

Let's break it down:

- `model`, `temperature`, `max_tokens`, `stream` are top-level scalar
  fields. (Note: `temperature` and `max_tokens` aren't standard OpenAI
  fields, but `cj` doesn't care — it passes them through.)
- `tools*` opens an array of tool definitions.
- Each tool has `type`, `function`. The `function` field has no value,
  so its value is a nested object.
- Inside `function`, `parameters` is again a nested object, with
  `properties` and `required` as nested arrays/objects.
- The `recency` field uses `enum*` to indicate an array (required even
  though the head name implies "enum").
- The `minimum`/`maximum` fields are not standard `.cc` — they pass
  through as JSON keys.

Converting to JSON:

```bash
$ cj search.cc
{"model":"gpt-4o","temperature":0.3,"max_tokens":2000,"stream":true,"tools":[{"type":"function","function":{"name":"web_search","description":"Search the web and return the top results","parameters":{"type":"object","properties":{"query":{"type":"string","description":"The search query"},"num_results":{"type":"integer","description":"How many results to return (1-10)","minimum":1,"maximum":10},"recency":{"type":"string","description":"Filter by time","enum":["day","week","month","any"]}},"required":["query"]}}}]}
```

Ready to POST to the OpenAI API.

---

# Part III — OpenAI Cookbook

This part is a collection of real-world patterns. Each chapter shows a
complete, runnable example.

## 11. Simple functions

The simplest useful tool: a function with one parameter.

```cc
# examples/simple_function.cc
model gpt-4o-mini
tools*
    type function
    function
        name get_current_time
        description Return the current time in the user's timezone
        parameters
            type object
            properties
                timezone
                    type string
                    description IANA timezone, e.g. America/Los_Angeles
            required*
                timezone
```

Convert:

```bash
$ cj simple_function.cc
```

The JSON output is one line. Send it to the API as the request body.

### A function with no parameters

Some functions take no arguments. Use an empty `properties` object and
empty `required` array:

```cc
tools*
    type function
    function
        name roll_dice
        description Roll a six-sided die and return the result
        parameters
            type object
            properties
            required*
```

Note the empty `properties` line (no value, no nested content). The
empty `required*` produces `[]`.

## 12. Enum-constrained parameters

For string parameters that should only accept specific values, use an
array. By convention, OpenAI uses the field name `enum`, but in `.cc`
you must use the `+` or `*` suffix to mark it as an array.

```cc
# examples/enum_tool.cc
model gpt-4o-mini
tools*
    type function
    function
        name set_unit
        description Set the temperature unit
        parameters
            type object
            properties
                unit
                    type string
                    description Temperature unit
                    enum*
                        celsius
                        fahrenheit
                        kelvin
            required*
                unit
```

becomes

```json
{"model":"gpt-4o-mini","tools":[{"type":"function","function":{"name":"set_unit","description":"Set the temperature unit","parameters":{"type":"object","properties":{"unit":{"type":"string","description":"Temperature unit","enum":["celsius","fahrenheit","kelvin"]}},"required":["unit"]}}}]}
```

Notice how the enum values are bare identifiers in `.cc` and become
strings in JSON. No quoting needed because they're plain identifiers.

If you have an enum value with spaces (unusual but possible), quote it:

```cc
enum*
    "first value"
    "second value"
```

## 13. Multi-turn messages

For conversations with history, the `messages` field is an array of
message objects.

```cc
# examples/chained_messages.cc
model gpt-4o
messages+
    role system
    content You are a helpful assistant.
    ,
    role user
    content What is the capital of France?
    ,
    role assistant
    content The capital of France is Paris.
    ,
    role user
    content And what is its population?
```

becomes

```json
{"model":"gpt-4o","messages":[{"role":"system","content":"You are a helpful assistant."},{"role":"user","content":"What is the capital of France?"},{"role":"assistant","content":"The capital of France is Paris."},{"role":"user","content":"And what is its population?"}]}
```

The `,` between messages is the array separator. Each message is a
multi-line object with `role` and `content` (and any other OpenAI
fields like `name` for naming speakers).

### Long system prompts

For long system messages, use `\n` escapes in a quoted string:

```cc
messages+
    role system
    content "You are a Python expert.\n\nRules:\n1. Always use type hints.\n2. Write docstrings.\n3. Prefer stdlib over external libs.\n\nBe concise."
    ,
    role user
    content Write a quicksort function.
```

The JSON output has a real newline character in the content string,
which OpenAI renders as a properly-formatted system prompt.

## 14. Generation parameters

Beyond `model`, the OpenAI API accepts parameters like `temperature`,
`max_tokens`, `top_p`, `frequency_penalty`, `presence_penalty`, and
`stop`. These go at the top level alongside `messages` and `tools`.

```cc
# examples/boolean_flag.cc
model gpt-4
stream true
temperature 0.7
max_tokens 2048
top_p 0.9
frequency_penalty 0.5
presence_penalty 0.0
stop*
    "\n\nUser:"
    "\n\nAssistant:"
```

Notice:

- `stream true` is a boolean
- `temperature 0.7` and the rest are numbers
- `stop*` is an array of strings (the `*` makes it an array)
- The stop strings use `\n` escapes because they contain newlines

These all pass through to the OpenAI API as-is.

## 15. Multi-tool configurations

For an agent that uses multiple tools, list them all in the `tools`
array. Each is a separate object.

```cc
# examples/agent_with_tools.cc
model gpt-4o
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
                    description City name
            required*
                location
    ,
    type function
    function
        name search_web
        description Search the web
        parameters
            type object
            properties
                query
                    type string
            required*
                query
    ,
    type function
    function
        name send_email
        description Send an email
        parameters
            type object
            properties
                to
                    type string
                subject
                    type string
                body
                    type string
            required*
                to
                subject
                body
```

Three tools, separated by `,`. `cj` produces a single JSON with a
3-element `tools` array.

### Sharing parameter definitions

If two tools share a parameter (e.g., both have a `query` string), you
have to duplicate the definition. `.cc` doesn't have a way to share
schema fragments — it's a flat file, not a template engine.

For real production, consider generating the `.cc` file from a
higher-level template (YAML, TOML, or your favorite format) and
running `cj` on the output. This gives you the DX of templates with
the output format of `.cc`.

## 16. Streaming and advanced parameters

`stream: true` enables server-sent events. The OpenAI API returns the
response incrementally. `cj` doesn't handle the streaming itself — it
just emits the request body.

```cc
model gpt-4o
stream true
tools*
    type function
    function
        name calculate
        description Evaluate a math expression
        parameters
            type object
            properties
                expression
                    type string
                    description A valid Python expression
            required*
                expression
```

Beyond the basics, OpenAI supports:

- `tools[].function.strict: true` (Structured Outputs) — guarantees
  the model follows the schema
- `response_format` — for JSON mode
- `logprobs` and `top_logprobs` — for logprob analysis
- `seed` — for reproducible outputs

These are all just fields in `.cc`. `cj` doesn't validate them, so
anything the API accepts will pass through:

```cc
model gpt-4o
seed 42
logprobs true
top_logprobs 5
response_format
    type json_object
tools*
    type function
    function
        name extract_data
        description Extract structured data
        parameters
            type object
            properties
                data
                    type string
            required*
                data
        strict true
```

---

# Part IV — JSON Mode and Round-trip

## 17. The -d flag

`cj -d` (or `--decode`) reads JSON and produces `.cc`:

```bash
$ echo '{"model":"gpt-4","messages":[{"role":"user","content":"hi"}]}' | cj -d
messages*
  role "user"
  content "hi"
model "gpt-4"
```

That's the full syntax. The flag forces JSON mode, regardless of what
the auto-detector thinks.

### When to use `-d` explicitly

The auto-detect is usually right, but use `-d` when:

- The input is JSON but starts with a primitive (`42`, `"hello"`,
  `true`) — these are ambiguous in `.cc`
- You want to make the intent clear in a script

For most cases, you can omit the flag and let the auto-detector work.

### The -e flag

`cj -e` (or `--encode`) is the explicit form of the default: read
`.cc`, output JSON. It's there for symmetry with `-d`, but you
usually don't need it.

## 18. Format auto-detection

`cj` looks at the input structure to decide the direction. The rules:

| First non-whitespace | Format |
|---|---|
| `{` or `[` | JSON object/array |
| `"` | JSON string |
| digit or `-digit` | JSON number |
| `true`, `false`, `null` followed by only whitespace | JSON literal |
| anything else (letter, `_`, `#`) | `.cc` |

The trickiest case is when the input starts with a letter. `true`
could be a JSON boolean or a `.cc` field name. The detector
disambiguates by looking at what follows:

- `true` alone (or followed by whitespace) → JSON
- `true field value` → `.cc` (the parser would treat it as a field
  named `true` with value `field value`)

The "followed by only whitespace" rule is conservative: it captures
all valid JSON primitives, and only misclassifies `.cc` inputs that
happen to be a single primitive-like word with no value (a rare edge
case in practice).

### UTF-8 BOM

If the input starts with a UTF-8 BOM (`\xEF\xBB\xBF`), `cj` skips it
before detection. Some Windows tools add BOMs to JSON files; this
keeps things working.

## 19. Round-trip workflows

The most common use of `cj` is round-tripping: JSON → `.cc` → edit →
`.cc` → JSON. Here's the workflow:

### Step 1: Get a starting JSON

Either from the OpenAI Playground, a saved request, or a colleague's
config file.

### Step 2: Convert to `.cc`

```bash
$ cj -d request.json > request.cc
```

### Step 3: Edit

Open `request.cc` in your editor. Add tools, change parameters, add
comments. The `.cc` is much easier to edit than the JSON.

### Step 4: Convert back

```bash
$ cj request.cc > new-request.json
```

### Step 5: Verify

If you want to be sure the round-trip didn't lose data, compare:

```bash
$ diff <(jq -S . request.json) <(jq -S . new-request.json)
```

The `-S` flag sorts keys, so the diff is hash-order independent.

### Caveat: field order

`cj` uses hash maps internally, so field order in the output is
hash-determined, not source-determined. This means the round-trip
`.cc` may have fields in a different order than the original.

For most uses, this doesn't matter — JSON is unordered semantically.
But if you rely on field order (e.g., for some serialization library
that's strict about it), use `jq` to re-sort before comparing.

### Caveat: formatting

The round-trip `.cc` may have slightly different formatting than
your original:

- Strings that don't need quoting (no special chars) are unquoted
- Strings that need quoting get minimal quotes (`"..."`)
- Comments are lost
- Whitespace is normalized to 2-space indent

For most use cases, this is what you want — the round-trip output
looks like a hand-edited `.cc` file. If you need to preserve the
original formatting, keep both versions and merge manually.

## 20. Editing existing JSON

Suppose you have a JSON file and want to make a small change. The
naive approach:

1. Open the JSON in an editor
2. Find the field to change
3. Edit it carefully (mind the commas, brackets, quotes)
4. Save

`cj` makes this easier:

1. `cj -d file.json > file.cc`
2. Edit `file.cc` (much easier — no `{{}}` to count)
3. `cj file.cc > new-file.json`

For a single small change, the round-trip overhead might not be worth
it. But for tools with many fields, nested parameters, or repeated
patterns, the `.cc` representation is dramatically easier to edit.

---

# Part V — Internals

This part explains how `cj` works. Read it if you want to extend `cj`
or just understand its limits.

## 21. How the parser works

`cj` has two parsers: one for `.cc` and one for JSON. They share an
internal `Value` representation.

### The `.cc` parser

The `.cc` parser has three stages:

1. **Tokenize**: split input into lines, strip whitespace, track
   indent and line number. Whole-line comments (lines starting with
   `#` after indent) are dropped.

2. **Parse object**: walk the lines, consuming them as fields. A
   field is either a scalar value (on the same line) or a nested
   object/array (on subsequent deeper-indented lines).

3. **Parse array**: walk items separated by `,`. For each item, peek
   at the structure to decide scalar vs object, then parse
   accordingly.

The data structure is `StringHashMap(Value)` for objects and
`ArrayList(Value)` for arrays. The `Value` union has variants for
null, bool, int, float, string (two flavors: borrowed or owned),
array, and object.

### The JSON parser

Recursive descent:

1. **Object**: `{ key: value, key: value, ... }` — strings as keys,
   any value type
2. **Array**: `[ value, value, ... ]`
3. **String**: `"..."` with JSON escape support, including `\uXXXX`
4. **Number**: int or float, including negative and scientific
5. **Bool / null**: literal keywords

The JSON parser is strict: it errors on unknown escapes, missing
commas, trailing content, etc. This is intentional — JSON is a
wire format, not a free-form language.

### Shared Value type

Both parsers produce the same `Value` type. This is what makes
round-trip possible: parse `.cc` to Value, serialize to JSON, parse
JSON to Value, serialize to `.cc`.

Strings have two variants in `Value`:

- `string_v: []const u8` — borrowed from the input, zero-copy
- `string_alloc_v: []u8` — owned, used when the string needed
  unescaping

The deinit function frees `string_alloc_v` and recurses through
arrays/objects, but leaves `string_v` as a dangling reference (the
input buffer is freed by the caller).

## 22. How the writer works

Two writers: one for JSON (compact or pretty) and one for `.cc`.

### JSON writer

Walks the Value tree recursively:

- Scalars → literal (`true`, `42`, `3.14`, `null`) or quoted string
- Strings → quoted with JSON escapes
- Arrays → `[item, item, ...]`
- Objects → `{key: value, key: value, ...}`

The compact mode emits everything on one line. The pretty mode uses
2-space indent and newlines between elements.

### `.cc` writer

Also walks the tree, but with format-specific rules:

- Object fields: `key value` on one line (or nested if value is
  object)
- Array of scalars: each on its own line, no separator
- Array of objects: each block separated by `,`
- Empty array: just the `+` or `*` suffix (no items)

For strings, the `.cc` writer uses a quoting heuristic to decide when
to add quotes. It quotes when:

- The value contains `"`, `\`, newlines, or starts with `#`
- The value is all whitespace
- The value is a reserved word (`true`, `null`, etc.)
- The value looks like a number (`42`, `-7`, `3.14`)

Otherwise, it leaves the value unquoted. This makes round-tripped
`.cc` files look natural.

## 23. Testing strategy

`cj` has 46 tests covering:

- **Tokenizer**: line splitting, indent counting, comment skipping
- **.cc parser**: scalar types, nested objects, arrays, escape
  sequences, the scalar-vs-object disambiguation heuristic
- **JSON parser**: all value types, escapes, unicode, strict error
  cases
- **.cc writer**: scalar objects, array of objects, quoting rules
- **Helpers**: `isValidIdentifier`, `needsQuoting`, `jsonEqual`
- **Edge cases**: empty object/array, scientific notation, deep
  nesting, mixed-type arrays, whitespace tolerance
- **Format detection**: the auto-detect rules
- **Round-trip**: 10 real OpenAI tool samples, all verified to
  produce semantically equal JSON after `.cc → JSON → .cc → JSON`

The round-trip test reads a `.cc` file, converts to JSON, converts
back to `.cc`, converts to JSON again, and uses `jsonEqual` to check
the two JSONs are equivalent.

### Running tests

```bash
zig build test
```

Expected output: `46 pass (46 total)`.

## 24. Performance notes

`cj` is a single-pass parser over files typically under 10 KB.
Performance is not a primary concern, but for the curious:

- **Parse**: O(n) where n is input size. One allocation for the
  hash map, plus per-string allocations for escaped strings.
- **Write**: O(n). Single ArrayList, no intermediate structures.
- **Memory**: zero-copy for unescaped strings (borrowed from input).
  Escaped strings are allocated.

Empirically, a 10 KB OpenAI tools JSON parses in well under 10 ms
on a modern machine. The bottleneck is the hash map's allocation, not
the parsing itself.

`cj` is not designed for streaming. It reads the entire input into
memory before parsing. If you have multi-megabyte requests, you might
want a different tool.

---

# Appendices

## A. .cc Grammar Reference

A formal-ish grammar for `.cc`:

```
file        = (line newline)*
line        = comment | field | separator | empty
comment     = '#' .* (to end of line, dropped)
empty       = whitespace*  (blank line, dropped)
separator   = ','  (only in array context)
field       = name suffix? value? continuation?
name        = ident_start ident_cont*  (no leading whitespace)
ident_start = letter | '_'
ident_cont  = letter | digit | '_'
suffix      = '+' | '*'  (marks this field as an array)
value       = scalar | string
scalar      = int | float | bool | null
string      = unquoted | quoted
unquoted    = .*  (rest of line, after name and whitespace)
quoted      = '"' .* '"'  (with JSON escape support)
continuation = (newline indented_field)*  (for nested objects/arrays)
indented_field = whitespace+ field
```

In plain English:

- A file is a sequence of lines
- Each line is a field, a separator, a comment, or blank
- A field has a name (identifier) and an optional value
- A field with a `+` or `*` suffix is an array
- A field with no value has its value on subsequent indented lines
- Values are auto-typed (number, bool, null, string)

## B. CLI Reference

```
cj [options] [<input>]

Options:
  -p, --pretty    Pretty-print JSON output (default: compact, single line)
  -d, --decode    Force JSON → .cc (overrides auto-detect)
  -e, --encode    Force .cc → JSON (default; explicit form)
  -h, --help      Show help and exit

Input:
  If <filename> is given, read from that file.
  Otherwise, read from stdin.

Output:
  Always written to stdout.

Exit codes:
  0  Success
  1  Parse error or I/O error
```

## C. Escape Sequence Reference

Inside a quoted string (either `.cc` or JSON), these escapes are
recognized:

| Escape | Meaning |
|---|---|
| `\"` | Literal `"` |
| `\\` | Literal `\` |
| `\/` | Literal `/` |
| `\n` | Newline (LF) |
| `\t` | Tab |
| `\r` | Carriage return |
| `\b` | Backspace |
| `\f` | Form feed |
| `\uXXXX` | Unicode code point (BMP only) |

Anything else after a backslash is a parse error (in JSON mode) or
kept as a literal (in `.cc` mode, for robustness).

## D. Sample files

The `examples/` directory has 10 ready-to-use `.cc` files plus their
expected JSON output:

| File | Purpose |
|---|---|
| `get_weather.cc` | Simple single-parameter function |
| `web_search.cc` | Function with enum-constrained parameter |
| `send_email.cc` | Function with multiple required parameters |
| `calculator.cc` | Function with enum operation + two numbers |
| `chained_messages.cc` | Multi-turn conversation |
| `enum_tool.cc` | Demonstrates `enum+` array convention |
| `long_prompt.cc` | Long system prompt with `\n` escapes |
| `image_search.cc` | Function with multiple params including enum |
| `unicode_prompt.cc` | Chinese / Japanese / Korean characters |
| `boolean_flag.cc` | Top-level boolean and integer params |

Use these as starting points for your own tool configs.

## E. Known limitations

| Limitation | Workaround |
|---|---|
| Field order is hash-determined, not source order | Use `jq -S` to re-sort before comparing |
| JSON keys with escape characters leak memory in some edge cases | OpenAI tools use plain identifiers; not a practical issue |
| Float precision: `f64` may not match JSON string exactly | Don't rely on bitwise float equality across round-trips |
| No multi-line heredoc strings | Use `\n` escapes in quoted strings |
| No schema validation | Use OpenAI's API errors to catch schema issues |
| No streaming | Read the entire input into memory |

## F. Glossary

**DSL** — Domain-Specific Language. A small language designed for one
purpose. `.cc` is a DSL for writing OpenAI tool configs.

**JSON Schema** — A vocabulary for describing JSON structures. The
OpenAI API uses a subset of JSON Schema for `function.parameters`.

**OpenAI Chat Completions** — The API endpoint that takes a list of
messages and tools, returns a model-generated response. See the
[OpenAI docs](https://platform.openai.com/docs/api-reference/chat).

**Round-trip** — Converting in one direction, then back, ending with
semantically equivalent data. `cj` round-trips `.cc` ↔ JSON.

**StringHashMap** — A Zig data structure mapping string keys to values.
Used internally by `cj` for objects. Iteration order is hash order.

**Value** — The internal data structure `cj` uses to represent a
parsed document. A tagged union with variants for null, bool, int,
float, string, array, and object.

---

## About this book

`cj` is a small, focused tool. This book tries to be the same:
small, focused, complete. If you have feedback, suggestions, or
found a bug, please open an issue.

Happy writing!
