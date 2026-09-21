# JS semantics the port has to map

Every "Upstream" line below was **measured with the oracle** against the pinned
tag, not recalled. When you measure a new one, add it here and as a corpus case.

Status is `decided` (ADR number) or `open` (karr ticket). For an open entry, do
not pick a mapping locally — see the core skill, "Undecided mappings".

## Value kinds — decided, ADR 0001

| Template | Upstream |
|---|---|
| `{{ 1 == 1 }}`, `{{ t }}` (JSON `true`) | `true` |
| `{{ '1' + 1 }}` / `{{ 1 + 1 }}` | `11` / `2` |
| `{{ '3' * '2' }}` / `{{ '5' - 1 }}` | `6` / `4` |
| `{{ 1 == '1' }}` / `{{ 1 === '1' }}` | `true` / `false` |
| `{{ '10' < '9' }}` / `{{ 10 < 9 }}` | `true` / `false` |

Kind comes from `builtin::is_bool` / `builtin::created_as_number`. `==` is JS
loose equality, `===` strict; both are Runtime calls, never Perl's `==`/`eq`.

## Truthiness — decided by ADR 0001's kinds, mechanism in Runtime

Falsy in JS: `false`, `0`, `NaN`, `''`, `null`, `undefined`. **Truthy** where
Perl disagrees: the string `'0'`, an empty array, an empty object.
Measured: `'0'`, `[]`, `{}` → truthy; `0`, `''` → falsy; `{{ z or 'd' }}` with
`z = 0` → `d`; `{{ '0' and 1 }}` → `1` (and/or return the operand, not a bool).

## undefined vs null — open, ticket k2

| Template (`n` = JSON null, `u` missing) | Upstream |
|---|---|
| `{{ u }}` / `{{ n }}` | both empty |
| `{{ u is defined }}` / `{{ n is defined }}` | `false` / `true` |
| `{{ n is none }}` / `{{ u is undefined }}` | `true` / `true` |
| `{{ n.foo }}` / `{{ u.foo.bar }}` | both empty, no error |
| `{{ a.b.c }}` with `throwOnUndefined` | error `attempted to output null or undefined value` |

## Object key order — open, ticket k3

`{% for k, v in {b:1, a:2} %}` → `b=1;a=2;` (insertion order). `dump` →
`{"b":1,"a":2}`. `dictsort|join(',')` → `a,2,b,1`.

## Numbers — open, ticket k4

`1/3` → `0.3333333333333333` · `0.1+0.2` → `0.30000000000000004` · `1e21` →
`1e+21` · `10/4` → `2.5` · `7 // 2` → `3` · `2 ** 0.5` → `1.4142135623730951` ·
`1/0` → `Infinity` · `'a' * 2` → `NaN`.
Filters: `'3.7'|int` → `3` · `'x'|int` → empty · `'3.7abc'|float` → `3.7` ·
`2.5|round` → `3` · `-2.5|round` → `-2` · `[10,9,1]|sort` → `1,9,10` ·
`['b','A','c']|sort` → `A,b,c`.

## Strings are UTF-16 upstream — open, ticket k5

On `'héllo😀'`: `length` → `7`, `s.length` → `7`, `s[1]` → `é`, `reverse` →
splits the surrogate pair into two lone surrogates.

## Native JS members from templates — open, ticket k6

`s.toUpperCase()` works · `arr.join('-')` → `3-1-2` · `arr.length` → `3` ·
`arr.indexOf(1)` → `1`. Calling something missing:
`Error: Unable to call \`undefinedfn\`, which is undefined or falsey`.

## Stringification of containers — follows from k3/k6, mechanism in Runtime

`{{ [3,1,2] }}` → `3,1,2` · `{{ {} }}` → `[object Object]`.

## Regex literals — open, ticket k7

`{{ r/^h.l/.test(s) }}` → `true`. Oracle AST dumps a regex as
`{ "regex": <source>, "flags": <flags> }`.

## Callables, kwargs, `this`, callback API — open, ticket k8

## Escaping — port as is, no decision needed

Autoescape is **on by default**. The escape map is `& " ' < >` **plus backslash**:
`'` → `&#39;`, `\` → `&#92;`; backtick is not escaped. `urlencode` follows
`encodeURIComponent`: `'a b&c'` → `a%20b%26c`.

## Errors — port as is

Message format is asserted by upstream tests, keep it byte-identical:
`(unknown path) [Line 1, Column 15]\n  unknown block tag: foo` — note Line/Column
are **1-based in messages** while token/AST `lineno`/`colno` are **0-based**.
Error name: `Template render error`.
