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

Not pure insertion order (ADR 0011 amendment, k51): own keys enumerate array
indices first, ascending, then the rest in insertion order. `{"b":1, "2":2,
"1":3}` → `1;2;b;` · keys `a 10 9 01 -1 4294967295 4294967294 1.5` →
`9;10;4294967294;a;01;-1;4294967295;1.5;`. An index is the canonical ASCII
decimal of 0 … 4294967294: `0` is one; `00`, `-0`, `+1`, `' 1'`, `1e3`, `0x1`,
`''`, `"1\n"`, `٣`, `1٣` and `4294967296` and above are not. groupby's result
follows it: years `b 2019 a 10 2018 9` → `9|10|2018|2019|b|a|`. A plain caller
hash puts its indices first too and sorts only the rest (maintainer, k51):
`{b, 10, 9, a, 2}` → `2 9 10 a b`. Seam: Lib `keys` →
`_ordinary_own_property_keys` / `_is_array_index`. A caller-supplied
`Hash::Ordered` gets the JS rule too, indices first, then its own insertion
order (ADR 0011 "Caller-supplied ordered hashes", orchestrator call pending
the maintainer's confirmation, k51). Open: a `Tie::IxHash`-tied hash is
sorted like a plain one, its own order is not honoured (k78). A kwargs object
as a value (`u | default(b=1, a=2)`) iterates `b=1;a=2;__keywords=true;`
upstream, nothing in the port (KwArgs is not an object to Lib/member_lookup;
k79). The `loop` object and an import namespace are plain hashes and iterate
key-sorted, not in JS order (k80).

## Numbers — decided, ADR 0007

`1/3` → `0.3333333333333333` · `0.1+0.2` → `0.30000000000000004` · `1e21` →
`1e+21` · `10/4` → `2.5` · `7 // 2` → `3` · `2 ** 0.5` → `1.4142135623730951` ·
`1/0` → `Infinity` · `'a' * 2` → `NaN`.
Filters: `'3.7'|int` → `3` · `'x'|int` → empty · `'3.7abc'|float` → `3.7` ·
`2.5|round` → `3` · `-2.5|round` → `-2` · `[10,9,1]|sort` → `1,9,10` ·
`['b','A','c']|sort` → `A,b,c`.

## Math.round, Math.abs, Math.pow — port as is, mechanism in Lib; pow ties open, k74

`round` is `rounder(val * factor) / factor`, and Math.round is V8's
Float64Round — ceil(x), one less unless ceil(x) − 0.5 ≤ x — never x + 0.5:
`0.49999999999999994|round` → `0` · `4503599627370497|round` (2^52 + 1) →
`4503599627370497` · `-0.51|round` → `-1`. On [-0.5, -0] it gives -0, which
`1 / x` shows: `1 / (-0.5|round)` · `1 / (-0.2|round)` ·
`1 / (-0.5|round(0, 'ceil'))` → `-Infinity`. `abs` is Math.abs, which drops the
sign of zero: `1 / ((-0)|abs)` → `Infinity` (`1 / -0` → `-Infinity`). Math.pow
— `round`'s factor and the `**` operator — is IEEE pow but NaN where C's pow
gives 1: `1 ** (1/0)` · `(-1) ** (1/0)` · `1 ** (-1/0)` · `1 ** ('a' * 1)` →
`NaN`; `('a' * 1) ** 0` → `1` · `2 ** (1/0)` → `Infinity`. Open: V8's pow and glibc's disagree on some
exact-tie integer powers above 2^53 — `942 ** 6` → `698723607368084600`
upstream, `698723607368084500` in the port (k74). Seams: Lib `js_math_round` /
`js_math_ceil` / `js_math_floor` / `js_math_abs` / `js_math_pow`.

## parseInt and parseFloat — port as is, mechanism in Lib

`int` is `parseInt(value, base)`, base 10 unless given. Leading
StrWhiteSpaceChar and one sign go: `'-12px'` behind U+00A0, U+FEFF and a space
→ `-12` · `'+-1'|int('d')` → `d`. The radix goes through ToInt32:
`'11'|int(base=4294967298)` · `(base=-4294967294)` · `(base=2.9)` → `3`, but
`'11'|int('d', 2147483650)` → `d` (wraps negative, so NaN). 0 means 10, or 16
after a `0x` prefix, which radix 16 strips too: `'0x1f'|int(base=0)` /
`(base=16)` → `31` · `'0x1f'|int` and `'0x1f'|int('d', 8)` → `0` ·
`'0x'|int('d', 16)` → `d`. A zero keeps its sign: `1 / ('-0'|int)` →
`-Infinity`. Past 2^53 the spec leaves the value to the implementation. V8
rounds radix 10 and the powers of two correctly, ties to even —
`'9007199254740993'|int` → `9007199254740992`, 2^53 + 1 and 2^53 + 3 spelt in
radix 2 → `9007199254740992` / `9007199254740996` — but folds any other radix in
32-bit chunks, two roundings each, and can miss by an ulp:
`'1200221000112221021220201222011021'|int('d', 3)` → `9455897125430928`
(correctly rounded: `…926`) · `'wgwkw4s440gwg0'|int('d', 36)` →
`5.538717684257602e+21` (`…601e+21`). Seams: Lib `js_parse_int`,
`_js_to_int32`.

`float` is `parseFloat(val)`: the longest StrDecimalLiteral prefix, `Infinity`
spelt case-sensitively — `'Infinityx'|float` → `Infinity` · `'-Infinity'|float`
→ `-Infinity` · `'infinity'|float('nan')` and `'INFINITY'|float('nan')` → `nan`
(the default, as for any NaN) — with no hex and no numeric separator:
`'1e'|float` → `1` · `'.5'|float` → `0.5` · `'0x10'|float` → `0` ·
`'1_000'|float` → `1`; `1 / ('-0'|float)` → `-Infinity`. Seam: Lib
`js_parse_float`.

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

A plain property read (`arr[0]`, `arr.length`, `v[attr]`) throws only on
undefined / null — `u|first` → `TypeError: Cannot read properties of undefined
(reading '0')` — and names the key as V8 prints it, measured with
`[u]|join(',', k)`: a string as is, a number or boolean through ToString
(`1.5` → `'1.5'`, `true` → `'true'`), a dict literal, caller hash or keyword
arguments as `'#<Object>'`; an array, SafeString or regex key drops the
`(reading ...)` clause (`TypeError: Cannot read properties of undefined`).
Anything else is `member_lookup`. Seam: Runtime `js_member_read` /
`_js_read_error`.

copySafeness's `target.toString()` is the same read — `string` is
`r.copySafeness(obj, obj)`: `u|string` → `TypeError: Cannot read properties of
undefined (reading 'toString')` · `none|string` → `... of null (reading
'toString')`; any other target gives its JS ToString: `5|string` → `5` ·
`[1,2]|string` → `1,2` · `true|string` → `true` · `{}|string` →
`[object Object]`. An own `toString` member and a null prototype are k44. Seam:
Runtime `copy_safeness`.

Array `reduce` (sum's `arr.reduce`) is on the ADR 0008 surface: `'abc'|sum` →
`TypeError: arr.reduce is not a function` · `u|sum` → `... of undefined
(reading 'reduce')` · `[].reduce(f)` → `TypeError: Reduce of empty array with
no initial value`. A callbackfn that is not callable is checked first and
shown V8's way (Runtime `_js_not_callable_text`): `undefined` · `object null`
· `boolean true` · `number 1.5` · `number NaN` · `string "x"` (cut to 100 code
units, then `<...>`) · any object `object` — `[].reduce({})` → `TypeError:
object is not a function`.

lib.map over a non-array walks it as an array-like, `obj[i]` while `i <
obj.length`, through Runtime (`member_lookup`, `op_lt`): `{length: '2', '0':
'x', '1': 'y'}|reverse|join(',')` → `y,x` · length `'1.5'` → `b,a` · a
SafeString has a length but no indices (`abc` from a macro, `|reverse` → `,,`)
· a number or an object without length maps nothing. A numeric length that is
no array length, `{length: 2.5}` or `{length: -1}`, throws `RangeError: Invalid
array length` (`results.length = obj.length`). Seam: Lib `map`.

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

## `\d` is ASCII, `/i` without `u` folds only ASCII — ADR 0005, mechanism in Lib

urlize's emailRe is
`` /^[\w.!#$%&'*+\-\/=?\^`{|}~]+@[a-z\d\-]+(\.[a-z\d\-]+)+$/i ``.
`\d` is `[0-9]`: `'a@x3.com'|urlize` takes the `mailto:` branch, `'a@x٣.com'`
(U+0663) does not — tldRe links it as `http://a@x٣.com`. `/i` without `u`
canonicalises through toUpperCase but never maps a character above U+007F onto
ASCII, so `[a-z]` matches the 52 ASCII letters only: `'a@X.COM'` → `mailto:` ·
`'a@ſ.com'` (U+017F, upper `S`) · `'a@Kx.com'` (U+212A KELVIN SIGN, lower `k`) ·
`'a@ıx.com'` (U+0131, upper `I`) → no `mailto:`; the local part's `\w` is ASCII
as well: `'é@x.com'` → no `mailto:`. Perl's `/i` would take ſ and K (not ı),
its `\w` é and its `\d` ٣. Seams: Lib `js_digit_class` and `js_word_class`;
Filters spells `[a-z]` under `/i` as `[A-Za-z]` without `/i`.

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

## urlencode: encodeURIComponent, destructuring, for-in — port as is, mechanism in Lib and Runtime

encodeURIComponent leaves `A-Z a-z 0-9 - _ . ! ~ * ' ( )` and writes every
other code point as the uppercase %XX of its UTF-8 bytes:
`"-_.!~*'()a b&c/?#[]"|urlencode|safe` → `-_.!~*'()a%20b%26c%2F%3F%23%5B%5D` ·
`'😀'|urlencode` → `%F0%9F%98%80`. It walks code units (ADR 0012); a lone
surrogate has no UTF-8 form and throws: `'😀'|first|urlencode` →
`URIError: URI malformed`. Seam: Lib `js_encode_uri_component`.

An array goes through `keyvals.map(([k, v]) => ...)`, and that pattern runs the
iteration protocol on each element: an array by element, a string — a
SafeString's value too — by code point, `undefined` past the end:
`[['a','b','c'], ['x'], '😀b']|urlencode` →
`a=b&amp;x=undefined&amp;%F0%9F%98%80=b` · `[m()]|urlencode` with `m` a macro
returning `a😀b` → `a=%F0%9F%98%80`. Any other element has no Symbol.iterator
and throws V8's TypeError, the value rendered as for a call (Runtime
`_js_not_callable_text`, above): `[5]|urlencode` → `TypeError: number 5 is not
iterable (cannot read property Symbol(Symbol.iterator))` · `[1.5]` →
`number 1.5 ...` · `[true]` → `boolean true ...` · `[none]` → `object null ...`
· `[u]` → `undefined ...` · `[{}]` → `object ...` · `[m]` with `m` a macro →
`function ...`. Seam: Runtime `js_array_destructure`.

Any other non-string goes through `lib._entries(obj)`, a for-in, which over
undefined, null, a number, a boolean or a function enumerates nothing: `5`,
`none`, `u`, `true`, `1/0` and a macro `m` all `|urlencode` to `''`;
`{a: 1, b: 'x y'}|urlencode` → `a=1&amp;b=x%20y`. A primitive string never gets
there (`lib.isString` comes first); its for-in indices elsewhere are k59. Seam:
Lib `keys`.

## Errors — port as is

Message format is asserted by upstream tests, keep it byte-identical:
`(unknown path) [Line 1, Column 15]\n  unknown block tag: foo` — note Line/Column
are **1-based in messages** while token/AST `lineno`/`colno` are **0-based**.
Error name: `Template render error`.
