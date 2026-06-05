# cj

> 简洁的 `.cc` DSL ↔ OpenAI 兼容 JSON

`cj` 是一个小 CLI，用来手写 OpenAI Chat Completions 请求体
（tools / functions / messages / parameters）。用缩进驱动的 `.cc` DSL
替代嵌套 JSON，输出 OpenAI API 直接接受的格式；用 `-d` 也能反向转换。

## 为什么是 `.cc`

- **行数只有 JSON 的 1/4**——告别 `}}}` 噩梦
- **git diff 友好**——每行一个字段，没有 `{}` 噪音
- **支持注释和多行字符串**——JSON 没有这些
- **精确 round-trip**——`.cc` 和 JSON 互转后语义完全一致（hash 顺序无关）

## 安装

```bash
zig build              # 编译到 zig-out/bin/cj
zig build run -- file  # 编译并跑
```

需要 Zig 0.16+。Windows / Linux / macOS 都行。

## 用法

```bash
cj [options] [<input>]

Options:
  -p, --pretty    美化 JSON 输出（默认紧凑单行）
  -d, --decode    反向：JSON → .cc
  -e, --encode    正向：.cc → JSON（默认；显式形式）
  -h, --help      帮助
```

不传文件名从 stdin 读。**格式自动检测**——看首非空白字符：`{` 或 `[` 当 JSON，
否则当 .cc。用 `-d` 显式覆盖。

### 例子

```bash
# .cc → JSON（默认）
cj tools.cc
cj tools.cc -p                  # 多行美化

# JSON → .cc（-d）
cj -d tools.golden.json

# 流式
echo '{"a":1}' | cj             # 自动 JSON 模式 → 输出 .cc
echo 'a 1' | cj                 # 自动 .cc 模式 → 输出 JSON
echo 'model gpt-4' | cj -p

# Round-trip
cj tools.cc | cj                # 还原 .cc（字段顺序变化，语义一致）
```

## `.cc` DSL

### 字段

| 写法 | 含义 |
|---|---|
| `key value` | 标量值同行 |
| `key`（无值） | 值为下方更深缩进的对象 |
| `key+` / `key*` | 值为数组（两个后缀等价） |
| `key:` | 显式空对象/数组（少见） |

每个缩进级别 2 空格。Tab 也算一个缩进单位。

### 标量类型（自动推断）

| 输入 | 类型 |
|---|---|
| `42`、`-7` | int |
| `3.14`、`1.5e10` | float |
| `true`、`false` | bool |
| `null`、`none`、`~` | null |
| `"quoted text"` | string（带引号） |
| `unquoted text` | string（无引号，**整行**作为值） |

### 字符串

```cc
# 无引号——首空白后到行尾都是值
description Get weather, please.

# 有引号——含特殊字符时用
content "Hello, \"world\"!"
escapes "line1\nline2\ttab"
path "C:\\Users\\foo"
```

支持的转义：`\"` `\\` `\n` `\t` `\r` `\/` `\b` `\f`

### 数组

```cc
# 标量数组
required*
    location
    unit

# 对象数组——用 `,` 单独成行分隔项
messages+
    role system
    content 1
    ,
    role user
    content ls

# 隐式分隔（无 `,`）——如果所有项都是"key value"形式，解析器会识别为同对象
# 但**强烈建议显式用 `,`**，更安全可读
```

### 注释

```cc
# 整行注释
model gpt-4   # 暂不支持行尾注释（避免和字符串冲突）
```

## 完整示例

### 单工具（get_weather）

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

→ JSON：
```json
{"model":"gpt-4o-mini","tools":[{"type":"function","function":{"description":"Get current weather for a location","name":"get_weather","parameters":{"properties":{"location":{"description":"City and state, e.g. San Francisco, CA","type":"string"},"unit":{"description":"Temperature unit","type":"string","enum":["celsius","fahrenheit"]}},"type":"object","required":["location"]}}}]}
```

### 多轮对话

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

## `.cc` 速查

| 想写 | 写法 |
|---|---|
| 字符串字段 | `desc "Hello"` 或 `desc Hello world` |
| 数字字段 | `count 42`、`temp 3.14` |
| bool 字段 | `stream true` |
| null 字段 | `data null` |
| 嵌套对象 | 见下 |
| 数组（标量） | `arr*\n  item1\n  item2` |
| 数组（对象） | `arr+\n  f1 v1\n  f2 v2\n  ,\n  f1 v1\n  f2 v2` |
| 注释 | `# ...` |
| 字符串含 `"` | `"he said \"hi\""` |
| 字符串含 `\n` | `"line1\nline2"` |

**嵌套对象示例：**

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

## JSON 模式 (`-d`)

反向转换，从 OpenAI 输出的 JSON 还原成可编辑的 `.cc`：

```bash
cj -d api-response.json > editable.cc
# 编辑后
cj editable.cc > new-request.json
```

`.cc` 输出规则：
- **不加引号**如果值不含特殊字符（空格/逗号/句号等都 OK——它们在 .cc 值里无特殊语义）
- **加引号**如果值含 `"`、`\`、换行、起始 `#`、纯空白、保留字（`true`/`null`/`~`）、或看起来像数字

这保证 round-trip 后的 `.cc` 看起来跟你手写的差不多。

## 测试

```bash
zig build test
```

**46 个测试全过**：

- 10 fixture（真实 OpenAI 工具样本）
- 解析器单元测试（tokenize、parseObject、parseArray、parseScalar）
- JSON 解析器单元测试（基础类型、转义、unicode、严格错误）
- `.cc` 生成器单元测试
- helpers 单元测试（`isValidIdentifier`、`needsQuoting`、`jsonEqual`）
- 边界用例（空对象/数组、科学计数、深度嵌套、混合类型数组、空白容忍）
- **完整 round-trip**（10 个 fixture 全部 `.cc → JSON → .cc → JSON` 语义一致）

## 已知限制

| 限制 | 说明 |
|---|---|
| 字段顺序 | 用 `StringHashMap` 存，迭代顺序是哈希序不是源序；JSON 语义相等但字节可能不同 |
| Key 转义 | 极端情况：JSON key 含转义字符（`\n`、`\"` 等）时会泄漏——OpenAI 规范 key 全是简单标识符（`model`/`tools`/`name` 等），无此问题 |
| 浮点精度 | `.cc` 用 `f64` 表达，IEEE 754 边界值可能与 JSON 字符串不完全一致 |
| 多行字符串 | 暂不支持 `"""..."""` heredoc 形式——长 description 用 `\n` 拼接或单行 |

## 性能

- 解析：O(n)，单遍 + 一次 hash map 分配
- 输出：O(n)，单次 ArrayList 写入
- 零拷贝：无转义的字符串借用 input 切片
- 实测：10KB 的 OpenAI tools JSON < 10ms

## License

MIT

---

## 致谢

- 灵感来自 Claude / OpenAI Cookbook 的 tool 模板
- 写给所有在跟嵌套 JSON `}}}` 搏斗的 LLM 工程师
