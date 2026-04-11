# openlibrary_filter

EmergenceSystem filter that searches Open Library (Internet Archive) for books. No API key required.

## Input

```json
{"query": "dune frank herbert"}
```

| Field     | Type    | Default | Description              |
|-----------|---------|---------|--------------------------|
| `query`   | string  | —       | Title, author, or ISBN   |
| `timeout` | integer | `10`    | HTTP timeout in seconds  |

## Output

Up to 10 embryos, one per book:

```json
{
  "properties": {
    "url":    "https://openlibrary.org/works/OL118077W",
    "resume": "Frank Herbert (1965)",
    "title":  "Dune",
    "source": "openlibrary.org"
  }
}
```

## Capabilities

`openlibrary`, `books`, `library`, `isbn`, `literature`

## Usage

```bash
rebar3 shell
```

## License

Apache-2.0
