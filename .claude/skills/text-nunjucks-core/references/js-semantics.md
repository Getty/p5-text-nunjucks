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

## undefined vs null — decided, ADR 0006

| Template (`n` = JSON null, `u` missing) | Upstream |
|---|---|
| `{{ u }}` / `{{ n }}` | both empty |
| `{{ u is defined }}` / `{{ n is defined }}` | `false` / `true` |
| `{{ n is none }}` / `{{ u is undefined }}` | `true` / `true` |
| `{{ n.foo }}` / `{{ u.foo.bar }}` | both empty, no error |
| `{{ a.b.c }}` with `throwOnUndefined` | error `attempted to output null or undefined value` |

## Object key order — decided, ADR 0011

`{% for k, v in {b:1, a:2} %}` → `b=1;a=2;` (insertion order). `dump` →
`{"b":1,"a":2}`. `dictsort|join(',')` → `a,2,b,1`.

## Numbers — decided, ADR 0007

`1/3` → `0.3333333333333333` · `0.1+0.2` → `0.30000000000000004` · `1e21` →
`1e+21` · `10/4` → `2.5` · `7 // 2` → `3` · `2 ** 0.5` → `1.4142135623730951` ·
`1/0` → `Infinity` · `'a' * 2` → `NaN`.
Filters: `'3.7'|int` → `3` · `'x'|int` → empty · `'3.7abc'|float` → `3.7` ·
`2.5|round` → `3` · `-2.5|round` → `-2` · `[10,9,1]|sort` → `1,9,10` ·
`['b','A','c']|sort` → `A,b,c`.

## Strings are UTF-16 upstream — decided, ADR 0012

On `'héllo😀'`: `length` → `7`, `s.length` → `7`, `s[1]` → `é`, `reverse` →
splits the surrogate pair into two lone surrogates.
On `t = 'a😀b😀c'`: `t.indexOf('b')` → `3` · `t.lastIndexOf('😀', 3)` → `1` ·
`t.split('').length` → `7` · `''.split('')` → `[]` but `''.split(',')` → `['']` ·
`'abc'.substr(0, -1)` → `''` · `'！' < '😀'` → `false` (code units: U+FF01 >
U+D83D) · `{% for c in '😀ab' %}` runs 4 times. Seams: `Lib` `js_*` (ADR 0012).
With `e = '😀ab'`, `e[0]` and `e[1]` are the two lone halves of the pair. Glued
back together by `~`, `+`, `.concat()`, `replace`, Array `join` or the output
buffer they are the pair again: `(e[0] ~ e[1]) == '😀'` and `=== '😀'` →
`true`, `d[e[0] ~ e[1]]` with `d = {'😀': 'hit'}` → `hit`, `{{ e[0] }}{{ e[1] }}`
outputs `😀`. Decided by ADR 0012: every join goes through `Lib`
`js_string_append`, which re-pairs a lone high + lone low surrogate where two
strings meet (and only there), so no string holds a pair as two surrogate
characters and Perl `eq` and hash keys agree with JS.

## Native JS members from templates — decided, ADR 0008

`s.toUpperCase()` works · `arr.join('-')` → `3-1-2` · `arr.length` → `3` ·
`arr.indexOf(1)` → `1`. Calling something missing:
`Error: Unable to call \`undefinedfn\`, which is undefined or falsey`.

## Native calls on the wrong receiver — V8's TypeError, ADR 0010 / 0016, mechanism in Runtime

filters.js calls methods on values it never checked; the text is V8's, built
from the call site, not from the value. Receiver `undefined` / `null`: the read
throws — `undefined|trim` → `TypeError: Cannot read properties of undefined
(reading 'replace')`, `none|trim` → `... of null (reading 'replace')`. Any
other receiver without the method: the call throws `<src>.<name> is not a
function`, `<src>` being upstream's source text of the receiver — `5|lower` →
`TypeError: str.toLowerCase is not a function` · `5|truncate(2)` →
`input.lastIndexOf ...` · `[1]|wordcount` → `str.match ...` · `true|upper` →
`str.toUpperCase ...`; a call inside the receiver prints as `(...)`
(`ret.charAt(0).x()` → `ret.charAt(...).x is not a function`, measured in node).
Seam: Runtime `js_method_call($obj, $src, $name, @args)` and `js_string_this`
(a String method run with an engine regex); the filter passes upstream's
variable as `$src`. The method resolves through the ADR 0008 surface, so a
method missing there throws the same text even where JS has it.

## Case mapping — port as is, mechanism in Lib; Unicode version open, k64

JS maps by code point with the full default case conversion, SpecialCasing
included: `'ß'|upper` → `SS` · `'ﬁ'|upper` → `FI` · `('İ'|lower).length` → `2`
(`i` + U+0307) · `'ǅ'|lower` / `|upper` → `ǆ` / `Ǆ`. Final_Sigma, which Perl's
`lc` lacks, follows ICU's context test: `'ΑΣ'` → `ας` · `'ΑΣΑ'` → `ασα` ·
`'Α.Σ'` → `α.ς` · `'ΑΣ1'` → `ας1` · `'1Σ'` → `1σ` · `'ʰΣ'` → `ʰσ` (U+02B0 is
cased *and* case-ignorable; ICU counts it ignorable). Perl maps Latin-1 by
Unicode rules only under `unicode_strings`. Seams: Lib `js_to_lower_case` /
`js_to_upper_case`. Open: the oracle's Node 24 uses Unicode 17, Perl 5.40
Unicode 15 — `'ɤ'|upper` → `Ɤ` upstream, `ɤ` in the port (k64).

## GetSubstitution — port as is, mechanism in Lib

A regex `replace` takes `$` patterns in a string replacement:
`'abc'|replace(r/(b)/, '[$1$2$0$01$10]')` → `a[b$2$0bb0]c` ·
`r/b/` with `` [$&][$`][$'][$$][$] `` → `a[b][a][c][$][$]c` · with eleven groups
`[$11|$10|$1|$12|$011|$00|$100]` → `[k|j|a|a2|a1|$00|j0]` (two digits when that
group exists, else one digit and a literal) · `'ab'|replace(r/(a)|(z)/, '[$1|$2]')`
→ `[a|]b` · `$<n>` → the named group, `''` for an unknown name, literal `$<n>`
when the regex has no named group. `` $` `` / `$'` cut at code-unit positions
(ADR 0012). The **filter** with a string `old` inserts `new` literally:
`` 'abc'|replace('b', '[$&$`]') `` → `` a[$&amp;$`]c ``; the native
`'abc'.replace('b', '$&$&')` → `abbc` (k56). Seam: Lib `js_get_substitution`.

## Symbol.replace: empty matches, lastIndex, groups — ADR 0013, mechanism in Runtime

An empty match steps lastIndex one on and matching goes on from there:
`'aaa'|replace(r/a*/g, '-')` → `--` · `'abc'|replace(r//g, '-')` → `-a-b-c-` ·
`'ab'|replace(r/x*|a/g, '-')` → `-a-b-` (Perl's `s///g` gives `--b-`). `g`
starts at 0 whatever lastIndex was and ends at 0: with `re = r/a/g`,
`re.test('xa')` leaves lastIndex `2`, then `'aXa'|replace(re, '-')` → `-X-` and
lastIndex is `0`. `y` matches only at lastIndex and moves it: after
`r/a/y.test('a')`, `'aaa'` → `a-a`, lastIndex `2`; `'aab'` with `r/a/y` →
`-ab`, with `r/a/gy` → `--b`; `'baa'` with `r/a/gy` → `baa`. Neither flag:
the first match from 0, lastIndex untouched (`r/a/` after `test('xa')`:
lastIndex `0`, `'aXa'` → `-Xa`, lastIndex `0`). A replacer
gets `(matched, captures..., position, string[, groups])`; the groups object is
engine-built, so it iterates in group order: `'ab'|replace(r/(?<z>a)(?<b>b)/, f)`
with `f` looping over `g` → `z=a;b=b;`; a group that did not take part is
undefined, a duplicate name keeps its first place. Its null prototype
(`{{ g }}` → `TypeError: val.toString is not a function`) is open, k44. Seam:
Runtime `Regex->symbol_replace` / `_regexp_exec`.

## `\w` is ASCII — ADR 0005, mechanism in Lib

The engine's own `\w` (wordcount's `/\w+/g`) is `[A-Za-z0-9_]`:
`'héllo wörld_1 ünï'|wordcount` → `5` · `'a😀b'|wordcount` → `2` ·
`'ǅx Ⅳ'|wordcount` → `1`. Seam: Lib `js_word_class`. A template regex literal
is a different path: `'é'|replace(r/\w/, '-')` → `é` upstream, `-` in the port
(k49).

## Stringification of containers — follows from k3/k6, mechanism in Runtime

`{{ [3,1,2] }}` → `3,1,2` · `{{ {} }}` → `[object Object]`.

## Regex literals — decided, ADR 0013

`{{ r/^h.l/.test(s) }}` → `true`. Oracle AST dumps a regex as
`{ "regex": <source>, "flags": <flags> }`.

## Callables, kwargs, `this`, callback API — decided, ADR 0009

## Escaping — port as is, no decision needed

Autoescape is **on by default**. The escape map is `& " ' < >` **plus backslash**:
`'` → `&#39;`, `\` → `&#92;`; backtick is not escaped. `urlencode` follows
`encodeURIComponent`: `'a b&c'` → `a%20b%26c`.

## Errors — port as is

Message format is asserted by upstream tests, keep it byte-identical:
`(unknown path) [Line 1, Column 15]\n  unknown block tag: foo` — note Line/Column
are **1-based in messages** while token/AST `lineno`/`colno` are **0-based**.
Error name: `Template render error`.
