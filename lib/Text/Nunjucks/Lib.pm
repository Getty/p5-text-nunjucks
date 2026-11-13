package Text::Nunjucks::Lib;
# ABSTRACT: 1:1 port of Nunjucks src/lib.js -- foundation utilities and escaping

our $VERSION = '0.001';

use strict;
use warnings;
use builtin qw( is_bool created_as_number true false );
use Carp qw( croak );
use POSIX ();
use Scalar::Util qw( blessed refaddr );
use Text::Nunjucks::Lib::TemplateError;
use Text::Nunjucks::Lib::Error;

no warnings 'experimental::builtin';

# lib.js is a plain bag of exported functions accessed qualified as `lib.foo`.
# Ported as a class-method-only module (getty-perl-core "dispatch through the
# invocant"): every function is a method taking $self, callers use
# Text::Nunjucks::Lib->is_array($x), cross-calls go through $self. No instances.
# ADR 0001 designates this module the single home for value-kind checks.

#### module constants (var escapeMap / escapeRegex)

my %ESCAPE_MAP = (
  '&'  => '&amp;',
  '"'  => '&quot;',
  "'"  => '&#39;',
  '<'  => '&lt;',
  '>'  => '&gt;',
  '\\' => '&#92;',
);

my $ESCAPE_REGEX = qr/[&"'<>\\]/;

#### hasOwnProp

sub has_own_prop {
  my ( $self, $obj, $k ) = @_;
  my $r = ref $obj;
  return exists $obj->{$k} ? 1 : 0 if $r eq 'HASH';
  # array own indices; full native-member semantics (.length &c) are k6/Runtime
  if ( $r eq 'ARRAY' ) {
    return ( $k =~ /\A(?:0|[1-9][0-9]*)\z/ && $k <= $#$obj ) ? 1 : 0;
  }
  return 0;
}

#### lookupEscape

sub lookup_escape {
  my ( $self, $ch ) = @_;
  return $ESCAPE_MAP{$ch};
}

#### _prettifyError

sub _prettify_error {
  my ( $self, $path, $with_internals, $err ) = @_;

  if ( !( blessed($err) && $err->can('update') ) ) {
    # not one of ours, cast it
    $err = Text::Nunjucks::Lib::TemplateError->new($err);
  }
  $err->update($path);

  # Unless they marked the dev flag, show them a trace from here. In JS this
  # rebuilds a plain Error to scrub internal stack frames; Perl has no such
  # stack in the message, but reproducing "an object without update()" matters:
  # a re-prettified error must be re-wrapped, not updated again.
  if ( !$with_internals ) {
    my $old = $err;
    $err = Text::Nunjucks::Lib::Error->new( $old->message, name => $old->name );
  }

  return $err;
}

#### TemplateError -- Text::Nunjucks::Lib::TemplateError (own file)

#### escape

sub escape {
  my ( $self, $val ) = @_;
  return $val =~ s/($ESCAPE_REGEX)/$self->lookup_escape($1)/ger;
}

#### isFunction

sub is_function {
  my ( $self, $obj ) = @_;
  # plain coderef only; blessed / overloaded callables are k8 (callables) territory
  return ref($obj) eq 'CODE' ? 1 : 0;
}

#### isArray

sub is_array {
  my ( $self, $obj ) = @_;
  return ref($obj) eq 'ARRAY' ? 1 : 0;
}

#### isString

sub is_string {
  my ( $self, $obj ) = @_;
  # ADR 0001: a string is a defined non-ref scalar that is neither a boolean
  # nor created-as-number. A numeric *string* ('5') is a string; 5 is not.
  return ( defined($obj) && !ref($obj) && !is_bool($obj) && !created_as_number($obj) )
    ? 1 : 0;
}

#### isObject

sub is_object {
  my ( $self, $obj ) = @_;
  # plain hashref only; blessed objects are k6/Runtime member-access territory
  return ref($obj) eq 'HASH' ? 1 : 0;
}

#### _prepareAttributeParts

sub _prepare_attribute_parts {
  my ( $self, $attr ) = @_;

  # JS: if (!attr) return [];  -- JS falsiness, NOT Perl's. See _falsy below.
  return [] if $self->_falsy($attr);

  # JS: if (typeof attr === 'string') return attr.split('.');  (-1 keeps trailing empties)
  return [ split /\./, $attr, -1 ] if $self->is_string($attr);

  return [$attr];
}

#### getAttrGetter

sub get_attr_getter {
  my ( $self, $attribute ) = @_;
  my $parts = $self->_prepare_attribute_parts($attribute);

  return sub {
    my ($item) = @_;
    my $_item = $item;

    for my $part (@$parts) {
      # If item is not an object, and we still got parts to handle, roll out to
      # undefined.
      if ( $self->has_own_prop( $_item, $part ) ) {
        $_item = ref($_item) eq 'HASH'  ? $_item->{$part}
               : ref($_item) eq 'ARRAY' ? $_item->[$part]
               :                          undef;
      } else {
        return undef;
      }
    }

    return $_item;
  };
}

#### groupBy

sub group_by {
  my ( $self, $obj, $val, $throw_on_undefined ) = @_;
  my $result   = {};
  my $iterator = $self->is_function($val) ? $val : $self->get_attr_getter($val);

  for my $i ( 0 .. $#$obj ) {
    my $value = $obj->[$i];
    my $key   = $iterator->( $value, $i );

    # JS: if (key === undefined && throwOnUndefined === true)
    if ( !defined($key)
      && defined($throw_on_undefined)
      && is_bool($throw_on_undefined)
      && $throw_on_undefined )
    {
      die Text::Nunjucks::Lib::Error->new(
        'groupby: attribute "' . $val . '" resolved to undefined',
        name => 'TypeError'
      );
    }

    # JS object keys are strings; an undefined key becomes "undefined". Other
    # non-string keys (booleans, objects) follow JS string coercion, whose
    # mechanism is k6/Runtime -- numbers already stringify identically here.
    my $hkey = defined($key) ? $key : 'undefined';
    push @{ $result->{$hkey} //= [] }, $value;
  }

  return $result;
}

#### toArray

sub to_array {
  my ( $self, $obj ) = @_;
  # Array.prototype.slice.call(obj) -- realistic use is a shallow arrayref copy
  return [ @$obj ] if ref($obj) eq 'ARRAY';
  # slice.call(string) -> its UTF-16 code units, the same list as split('')
  return $self->js_split( $obj, '' ) if $self->is_string($obj);
  return [];
}

#### without

sub without {
  my ( $self, $array, @contains ) = @_;
  my $result = [];
  return $result unless $array;    # JS !array (array is arrayref|undef here)

  my $length = scalar @$array;
  my $index  = -1;

  while ( ++$index < $length ) {
    if ( $self->index_of( \@contains, $array->[$index] ) == -1 ) {
      push @$result, $array->[$index];
    }
  }
  return $result;
}

#### repeat

sub repeat {
  my ( $self, $char, $n ) = @_;
  my $str = '';
  # JS: for (let i = 0; i < n; i++) -- runs (ceil of) fractional n times, unlike
  # Perl's `1..$n` which truncates. center() feeds fractional counts (spaces/2).
  for ( my $i = 0; $i < $n; $i++ ) {
    $self->js_string_append( $str, $char );    # str += char_ (ADR 0012)
  }
  return $str;
}

#### each

sub each {
  my ( $self, $obj, $func, $context ) = @_;
  return if !defined $obj;    # JS obj == null

  # array / array-like branch; context (`this`) is k8 and not modelled
  if ( ref($obj) eq 'ARRAY' ) {
    for my $i ( 0 .. $#$obj ) {
      $func->( $obj->[$i], $i, $obj );
    }
  }
}

#### map

sub map {
  my ( $self, $obj, $func ) = @_;
  my $results = [];
  return $results if !defined $obj;

  # obj.map(func) -- native Array.map passes (element, index, array)
  for my $i ( 0 .. $#$obj ) {
    $results->[$i] = $func->( $obj->[$i], $i, $obj );
  }
  return $results;
}

#### asyncIter

sub async_iter {
  my ( $self, $arr, $iter, $cb ) = @_;
  my $i = -1;

  my $next;
  $next = sub {
    $i++;
    if ( $i < scalar @$arr ) {
      $iter->( $arr->[$i], $i, $next, $cb );
    } else {
      $cb->();
    }
  };

  $next->();
}

#### asyncFor

sub async_for {
  my ( $self, $obj, $iter, $cb ) = @_;
  # JS: lib.keys(arr || {}) -- JS falsiness, not Perl's `// {}` which only
  # guarded undef and let a 0 / '' / false through to crash keys() on the deref.
  # None (JS null) is a Runtime sentinel that Lib does not know (ADR 0006); the
  # only caller that can pass a null iterable, Runtime::async_each, guards it
  # there before delegating, so _falsy (kind-based, no None) suffices here.
  my $keys = $self->keys( $self->_falsy($obj) ? {} : $obj );
  my $len  = scalar @$keys;
  my $i    = -1;

  # Value lookup mirrors the ordering policy of keys() above (ADR 0011): a
  # Hash::Ordered (template dict literal / engine-built object) reads via ->get;
  # a plain hashref reads via ->{}. Lib doesn't reach Runtime->member_lookup
  # (Lib and Runtime don't form a dep cycle in either direction), so this is the
  # single seam -- the Runtime side mirrors it for its own async_all loop.
  my $lookup = ( blessed($obj) && $obj->isa('Hash::Ordered') )
    ? sub { my $k = shift; $obj->exists($k) ? $obj->get($k) : undef }
    : sub { my $k = shift; $obj->{$k} };

  my $next;
  $next = sub {
    $i++;
    my $k = $keys->[$i];
    if ( $i < $len ) {
      $iter->( $k, $lookup->($k), $i, $len, $next );
    } else {
      $cb->();
    }
  };

  $next->();
}

#### indexOf

sub index_of {
  my ( $self, $arr, $search, $from_index ) = @_;
  # Array.prototype.indexOf.call(arr || [], searchElement, fromIndex) -- uses
  # strict equality (===). See _strict_eq below.
  $arr = [] unless defined $arr;
  my $len = scalar @$arr;

  my $start = defined($from_index) ? int($from_index) : 0;
  if ( $start < 0 ) {
    $start += $len;
    $start = 0 if $start < 0;
  }

  for ( my $i = $start; $i < $len; $i++ ) {
    return $i if $self->_strict_eq( $arr->[$i], $search );
  }
  return -1;
}

#### keys (keys_)

sub keys {
  my ( $self, $obj ) = @_;
  # own enumerable keys. ADR 0011 sets the ordering policy in one place:
  #
  #   * Hash::Ordered (template dict literal / engine-built object): own keys
  #     in insertion order -- byte-identical to JS Object.keys.
  #   * Plain caller hash: key-sorted, the documented divergence (Perl hashes
  #     carry no insertion order to preserve; sorted gives a deterministic
  #     cross-PERL_HASH_SEED iteration where JS would have shown insertion
  #     order).
  #
  # _entries / _values / extend / async_for / member_lookup / the dump /
  # dictsort / list / items filters (k17) all reach the iterator here, so this
  # is the only seam the policy needs.
  #
  # Non-hash refs are an open latency: JS keys([10,20]) -> ['0','1'], but a
  # non-HASH ref dies here on the deref. The value model routes arrays through
  # async_iter / to_array, so this is believed unreachable; keys(undef) already
  # yields [] cleanly. Revisit if a k14/k17 call site reaches it.
  return [ $obj->keys ] if blessed($obj) && $obj->isa('Hash::Ordered');

  # Plain hash: sort CORE::keys (per-process-random Perl order) deterministically.
  my $arr = [];
  for my $k ( sort CORE::keys %$obj ) {
    push @$arr, $k if $self->has_own_prop( $obj, $k );
  }
  return $arr;
}

#### _entries

sub _entries {
  my ( $self, $obj ) = @_;
  return [ CORE::map { [ $_, $obj->{$_} ] } @{ $self->keys($obj) } ];
}

#### _values

sub _values {
  my ( $self, $obj ) = @_;
  return [ CORE::map { $obj->{$_} } @{ $self->keys($obj) } ];
}

#### extend / _assign

sub extend {
  my ( $self, $obj1, $obj2 ) = @_;
  $obj1 = {} unless $obj1;    # JS obj1 || {} (obj1 is hashref|undef; refs are truthy)
  for my $k ( @{ $self->keys($obj2) } ) {
    $obj1->{$k} = $obj2->{$k};
  }
  return $obj1;
}

# exports._assign = exports.extend
*_assign = \&extend;

#### inOperator

sub in_operator {
  my ( $self, $key, $val ) = @_;

  # JS: if (isArray(val) || isString(val)) return val.indexOf(key) !== -1;
  # Array.indexOf and String.indexOf differ in Perl, so the one JS branch
  # splits in two.
  if ( $self->is_array($val) ) {
    return $self->index_of( $val, $key ) != -1 ? true : false;
  }
  if ( $self->is_string($val) ) {
    # JS String.prototype.indexOf coerces the search value via ToString:
    # undefined -> "undefined", true -> "true", numbers -> their decimal form.
    # Perl's index() stringifies too, but undef -> "" (which matches at 0)
    # instead of "undefined". Coerce undef here to match JS. The full ToString
    # for other non-string values (booleans especially: true -> "true", not
    # Perl's "1") rides on k6 (native coercion) and is left to that decision.
    my $needle = defined($key) ? $key : 'undefined';
    return $self->js_string_index_of( $val, $needle ) != -1 ? true : false;    # code units (ADR 0012)
  }
  # Ordered hash (template dict literal / engine-built object, ADR 0011).
  if ( blessed($val) && $val->isa('Hash::Ordered') ) {
    return $val->exists($key) ? true : false;
  }

  if ( $self->is_object($val) ) {
    return exists( $val->{$key} ) ? true : false;    # key in val
  }

  die Text::Nunjucks::Lib::Error->new(
    'Cannot use "in" operator to search for "' . $key . '" in unexpected types.'
  );
}

#### JS regex character classes -- explicit ECMAScript sets (ADR 0005)

# JavaScript's \s is a FIXED ECMAScript set (WhiteSpace + LineTerminator), not
# Perl's \s. It includes U+00A0 (NBSP, a member of the lexer's whitespace_chars)
# and U+FEFF, and excludes U+0085; Perl's default /d \s additionally matches (or
# not) U+00A0 depending on whether the target SV carries the UTF-8 flag, so the
# same template would lex differently by how it reached the engine. The engine's
# own regexes therefore map JS \s to this explicit class, matched flag-
# independently under /u. Membership is oracle-verified via the lstripBlocks
# /^\s+$/ path (see t/10-lexer.t / the k10 report), never recalled:
#   WhiteSpace     U+0009 U+000B U+000C U+0020 U+00A0 U+FEFF
#                  + Unicode Zs: U+1680, U+2000-U+200A, U+202F, U+205F, U+3000
#   LineTerminator U+000A U+000D U+2028 U+2029
# \d and \w get the same treatment when the parser/filters first need them; only
# \s is needed so far (ADR 0005: added on demand, one seam per class, like
# _strict_eq / _falsy below).
my $JS_WHITESPACE_CLASS =
  qr/[\x09\x0A\x0B\x0C\x0D\x20\x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]/u;

sub js_whitespace_class {
  my ($self) = @_;
  return $JS_WHITESPACE_CLASS;
}

#### JS !x (falsiness) for _prepare_attribute_parts and future !x sites

# Provisional JS falsiness keyed to ADR 0001 kinds. JS falsy values are
# undefined/null, false, 0, NaN and '' -- but the string '0' is TRUTHY in JS
# (Perl disagrees), so this cannot be a bare Perl boolean test. Truthiness's
# mechanism is slated for Runtime (k14); this is the single Lib seam it will
# merge with, mirroring _strict_eq below.
sub _falsy {
  my ( $self, $x ) = @_;
  return 1 if !defined($x);
  return ( $x ? 0 : 1 ) if is_bool($x);                                 # false is falsy
  return ( ( $x == 0 || $x != $x ) ? 1 : 0 ) if created_as_number($x);  # 0 or NaN
  return ( $x eq '' ? 1 : 0 ) if $self->is_string($x);                  # '' falsy, '0' truthy
  return 0;                                                              # refs are truthy
}

#### JS === for index_of / in_operator membership

# Provisional strict-equality keyed to ADR 0001 kinds. This mirrors the === that
# lib.js's indexOf relies on via Array.prototype.indexOf, so it lives here 1:1;
# Runtime will grow its own === for the template operator (k14). Whether the two
# should share one mechanism is an open placement question -- see the k9 report.
sub _strict_eq {
  my ( $self, $a, $b ) = @_;

  return 1 if !defined($a) && !defined($b);
  return 0 if !defined($a) || !defined($b);

  my ( $ra, $rb ) = ( ref($a), ref($b) );
  return ( ( $ra && $rb && refaddr($a) == refaddr($b) ) ? 1 : 0 ) if $ra || $rb;

  my ( $ba, $bb ) = ( is_bool($a), is_bool($b) );
  return 0 if !$ba != !$bb;                    # one boolean, one not
  return ( ( $a == $b ) ? 1 : 0 ) if $ba;      # both booleans

  my ( $na, $nb ) = ( created_as_number($a), created_as_number($b) );
  return 0 if !$na != !$nb;                     # number vs string
  if ($na) {
    return 0 if $a != $a || $b != $b;           # NaN !== NaN
    return $a == $b ? 1 : 0;
  }
  return $a eq $b ? 1 : 0;                       # both strings
}

#### number_to_string -- ECMAScript Number::toString, shortest round-trip (ADR 0007)

# Not a src/lib.js function: ADR 0007 designates Lib the single home for the
# JS Number->String routine, and the JS *operators* that home in Runtime feed
# their numeric results back through it. It reproduces ECMAScript
# Number::toString: the shortest decimal that round-trips to the same IEEE
# double, then JS's exponent thresholds and the spellings Infinity / -Infinity
# / NaN. Every number reaching template output goes through it
# (Runtime::_js_to_string / suppress_value); nothing uses bare "$n".
#
# JS numbers are all IEEE doubles; a Perl scalar can hold an exact 64-bit
# integer no double can represent -- a literal like 1234567890123456789, or an
# IV product Perl computed exactly (123456789 * 987654321 stays exact in Perl,
# but JS rounds it). pack/unpack('d') forces the value through a C double first
# so the rounding matches Node's. Runtime's operators round their operands the
# same way before computing, so intermediates are doubles too.
my $NUM_POS_INF = 9**9**9;
my $NUM_NEG_INF = -$NUM_POS_INF;

sub number_to_string {
  my ( $self, $n ) = @_;

  $n = unpack( 'd', pack( 'd', $n ) );      # normalise to a real IEEE double

  return 'NaN'       if $n != $n;           # NaN is the only value != itself
  return 'Infinity'  if $n == $NUM_POS_INF;
  return '-Infinity' if $n == $NUM_NEG_INF;
  return '0'         if $n == 0;            # +0 and -0 both render "0"

  my $neg = $n < 0 ? 1 : 0;
  my $abs = $neg ? -$n : $n;

  # Shortest significant-digit count p (1..17) whose p-digit rounding of $abs
  # parses back to exactly $abs. 17 sig digits always round-trip a double, so
  # the loop terminates; sprintf %e gives the correctly-rounded p-digit form.
  my ( $digits, $e10 );
  for my $p ( 1 .. 17 ) {
    my $sci = sprintf( '%.*e', $p - 1, $abs );
    if ( 0 + $sci == $abs ) {
      $sci =~ /\A(\d)(?:\.(\d+))?e([+-]\d+)\z/
        or croak __PACKAGE__ . '->number_to_string cannot parse ' . $sci;
      $digits = $1 . ( defined $2 ? $2 : '' );
      $e10    = 0 + $3;
      last;
    }
  }

  # Strip trailing zeros for the spec's significant digits s (length k); the
  # decimal point position is n = e10 + 1 (value = s x 10^(n-k)).
  $digits =~ s/0+\z//;
  $digits = '0' if $digits eq '';
  my $k     = length $digits;
  my $point = $e10 + 1;

  my $out;
  if ( $k <= $point && $point <= 21 ) {
    $out = $digits . ( '0' x ( $point - $k ) );
  } elsif ( 0 < $point && $point <= 21 ) {
    $out = substr( $digits, 0, $point ) . '.' . substr( $digits, $point );
  } elsif ( -6 < $point && $point <= 0 ) {
    $out = '0.' . ( '0' x ( -$point ) ) . $digits;
  } elsif ( $k == 1 ) {
    my $e = $point - 1;
    $out = $digits . 'e' . ( $e >= 0 ? '+' : '-' ) . abs($e);
  } else {
    my $e = $point - 1;
    $out = substr( $digits, 0, 1 ) . '.' . substr( $digits, 1 )
      . 'e' . ( $e >= 0 ? '+' : '-' ) . abs($e);
  }

  return $neg ? '-' . $out : $out;
}

#### JS strings reckon in UTF-16 code units (ADR 0012)

# Not src/lib.js functions: ADR 0012 designates Lib the single home for the
# string operations JS defines over UTF-16 code units. Strings stay ordinary
# Perl character strings; the code-unit view is computed per call:
#
#   * the "unit form" of a string spells every astral character (U+10000 ..
#     U+10FFFF) as its two surrogate characters, so each Perl character of the
#     unit form IS one UTF-16 code unit, and Perl's own length / substr / index /
#     rindex / cmp run in code units on it;
#   * a result goes back through _js_from_units, which re-pairs every valid
#     high + low surrogate pair into its astral character. A surrogate left
#     without its partner -- a slice, split or index through a pair -- stays a
#     lone surrogate character, 1:1 with JS (ADR 0012 accepts them).
#
# The invariant: no string the engine builds holds a valid pair (a high
# surrogate U+D800..DBFF directly followed by a low one U+DC00..DFFF) as two
# surrogate characters -- a pair is always the one astral character. Seam
# results keep it through _js_from_units; joins keep it through
# js_string_append, the one way two strings are glued together (template `~`
# and string `+`, String concat / replace, Array join and toString, the output
# buffer, asyncAll's output, repeat). Because every string satisfies it, the
# two code-unit sequences JS compares are equal exactly when the Perl strings
# are, so Perl's eq and hash keys stand in for JS ==, ===, object keys and `in`
# over an array or object with no further mapping. A caller string that spells
# a pair as two surrogate characters is outside the invariant: the seams below
# give both spellings the same unit form, but eq and hash keys tell them apart.
#
# Index and length arguments follow one contract, because ToNumber lives in
# Runtime (ADR 0007) and Lib does not call into Runtime: an argument is a JS
# number (already through ToNumber) or undef for JS `undefined`, and undef means
# whatever `undefined` means for that parameter of that method. Search strings
# and separators arrive already through ToString.

my $JS_ASTRAL = qr/[\x{10000}-\x{10FFFF}]/;

# The last astral string converted and its unit form. Spelling the pairs out
# costs a Perl-level substitution per astral character, the eq that finds the
# string again a C-level compare, so a template that indexes one string in a
# loop ({{ s[i] }}) converts it once instead of once per index.
my ( $JS_UNITS_OF, $JS_UNITS );

sub _js_to_units {
  my ( $self, $s ) = @_;
  return $s unless $s =~ $JS_ASTRAL;
  return $JS_UNITS if defined($JS_UNITS_OF) && $JS_UNITS_OF eq $s;
  $JS_UNITS_OF = "$s";
  return $JS_UNITS = $s =~ s/($JS_ASTRAL)/$self->_js_surrogate_pair( ord $1 )/ger;
}

sub _js_surrogate_pair {
  my ( $self, $cp ) = @_;
  $cp -= 0x10000;
  return chr( 0xD800 + ( $cp >> 10 ) ) . chr( 0xDC00 + ( $cp & 0x3FF ) );
}

sub _js_from_units {
  my ( $self, $u ) = @_;
  return $u unless $u =~ /[\x{D800}-\x{DBFF}]/;
  return $u =~ s/([\x{D800}-\x{DBFF}])([\x{DC00}-\x{DFFF}])/
    chr( 0x10000 + ( ( ord($1) - 0xD800 ) << 10 ) + ( ord($2) - 0xDC00 ) )/ger;
}

# ECMAScript ToIntegerOrInfinity over an already-ToNumber'd value: NaN (and
# undef, JS undefined -> NaN) is 0, +-Infinity stays, the rest truncates to zero.
sub _js_to_integer_or_infinity {
  my ( $self, $n ) = @_;
  return 0 if !defined($n) || $n != $n;
  return $n if $n == $NUM_POS_INF || $n == $NUM_NEG_INF;
  return int($n);
}

# ECMAScript ToUint32 over an already-ToNumber'd value (String.prototype.split's
# limit): NaN and +-Infinity are 0, else truncate and wrap modulo 2^32.
sub _js_to_uint32 {
  my ( $self, $n ) = @_;
  return 0 if $n != $n || $n == $NUM_POS_INF || $n == $NUM_NEG_INF;
  my $m = POSIX::fmod( int($n), 4294967296 );
  return $m < 0 ? $m + 4294967296 : $m;
}

# Clamp an integer-or-infinity to [0, $len].
sub _js_clamp {
  my ( $self, $n, $len ) = @_;
  return $n < 0 ? 0 : $n > $len ? $len : $n;
}

# The code units [$from, $to) of a unit form, back as a Perl string.
sub _js_unit_range {
  my ( $self, $u, $from, $to ) = @_;
  return '' if $from >= $to;
  return $self->_js_from_units( substr( $u, $from, $to - $from ) );
}

#### js_string_append -- JS string concatenation, in place

# Appends $str to the caller's string variable -- $_[1] is aliased, so the
# buffer is extended in place and never copied -- and returns nothing. JS joins
# code units, so a lone high surrogate at the end of the buffer and a lone low
# one at the start of $str form a valid pair in JS's result; here they become
# the one astral character, which keeps the invariant above. Only that boundary
# is looked at: each side already holds the invariant, so no other pair can
# form, and the check is O(1) whatever the buffer's length -- a test of $str's
# first character, then a chop of the buffer's last one (put back unless it is
# a high surrogate). Not a /[\x{D800}-\x{DBFF}]\z/ match: a successful match
# shares the buffer copy-on-write, so the chop after it would copy the whole
# buffer, and an output of many re-paired halves would turn O(n^2).
sub js_string_append {
  my ( $self, undef, $str ) = @_;
  my $lo = ord $str;    # ord '' is 0
  if ( $lo >= 0xDC00 && $lo <= 0xDFFF ) {
    my $last = chop $_[1];    # '' on an empty buffer
    my $hi   = ord $last;
    if ( $hi >= 0xD800 && $hi <= 0xDBFF ) {
      $_[1] .= chr( 0x10000 + ( ( $hi - 0xD800 ) << 10 ) + ( $lo - 0xDC00 ) ) . substr( $str, 1 );
      return;
    }
    $_[1] .= $last;
  }
  $_[1] .= $str;
  return;
}

#### js_string_length -- String length

sub js_string_length {
  my ( $self, $s ) = @_;
  # one code unit per character, plus the second unit of each astral one; the
  # match first, because tr over a wide range costs ~20 ns per character even
  # on a string with no astral character in it
  return CORE::length($s) unless $s =~ $JS_ASTRAL;
  return CORE::length($s) + ( $s =~ tr/\x{10000}-\x{10FFFF}// );
}

#### js_char_at -- String.prototype.charAt(pos)

sub js_char_at {
  my ( $self, $s, $pos ) = @_;
  my $u = $self->_js_to_units($s);
  my $p = $self->_js_to_integer_or_infinity($pos);
  return '' if $p < 0 || $p >= CORE::length($u);
  return substr( $u, $p, 1 );    # one unit: an ordinary character or a lone surrogate
}

#### js_string_slice -- String.prototype.slice(start, end)

sub js_string_slice {
  my ( $self, $s, $start, $end ) = @_;
  my $u    = $self->_js_to_units($s);
  my $len  = CORE::length($u);
  my $from = $self->_js_to_integer_or_infinity($start);
  my $to   = defined($end) ? $self->_js_to_integer_or_infinity($end) : $len;
  $from = $from < 0 ? $len + $from : $from;    # negative counts from the end
  $to   = $to < 0   ? $len + $to   : $to;
  return $self->_js_unit_range( $u, $self->_js_clamp( $from, $len ), $self->_js_clamp( $to, $len ) );
}

#### js_substring -- String.prototype.substring(start, end)

sub js_substring {
  my ( $self, $s, $start, $end ) = @_;
  my $u    = $self->_js_to_units($s);
  my $len  = CORE::length($u);
  my $from = $self->_js_clamp( $self->_js_to_integer_or_infinity($start), $len );
  my $to   = defined($end) ? $self->_js_clamp( $self->_js_to_integer_or_infinity($end), $len ) : $len;
  ( $from, $to ) = ( $to, $from ) if $from > $to;    # substring swaps, slice does not
  return $self->_js_unit_range( $u, $from, $to );
}

#### js_substr -- String.prototype.substr(start, length) (ECMAScript Annex B)

sub js_substr {
  my ( $self, $s, $start, $length ) = @_;
  my $u    = $self->_js_to_units($s);
  my $size = CORE::length($u);
  my $from = $self->_js_to_integer_or_infinity($start);
  $from = $from < 0 ? $size + $from : $from;
  $from = $self->_js_clamp( $from, $size );
  # length undefined -> to the end; a negative or NaN length takes nothing
  # (JS 'abc'.substr(0, -1) is '', where Perl's substr would drop the last char)
  my $n = defined($length) ? $self->_js_clamp( $self->_js_to_integer_or_infinity($length), $size ) : $size;
  my $to = $from + $n > $size ? $size : $from + $n;
  return $self->_js_unit_range( $u, $from, $to );
}

#### js_string_index_of -- String.prototype.indexOf(searchString, position)

sub js_string_index_of {
  my ( $self, $s, $search, $position ) = @_;
  my $u = $self->_js_to_units($s);
  my $p = $self->_js_clamp( $self->_js_to_integer_or_infinity($position), CORE::length($u) );
  return index( $u, $self->_js_to_units($search), $p );
}

#### js_string_last_index_of -- String.prototype.lastIndexOf(searchString, position)

sub js_string_last_index_of {
  my ( $self, $s, $search, $position ) = @_;
  my $u = $self->_js_to_units($s);
  # NaN -- and so undefined -- searches from the end, unlike indexOf's 0
  my $p = ( !defined($position) || $position != $position )
    ? $NUM_POS_INF
    : $self->_js_to_integer_or_infinity($position);
  return rindex( $u, $self->_js_to_units($search), $self->_js_clamp( $p, CORE::length($u) ) );
}

#### js_split -- String.prototype.split(separator, limit), string separator

sub js_split {
  my ( $self, $s, $separator, $limit ) = @_;
  my $lim = defined($limit) ? $self->_js_to_uint32($limit) : 4294967295;
  return [] if $lim == 0;
  return [$s] unless defined $separator;    # split(undefined) -> [S]

  my $u = $self->_js_to_units($s);
  # split('') -> the code units themselves, an astral character as two lone
  # surrogates; ''.split('') is [] while ''.split(',') is [''] (oracle)
  if ( $separator eq '' ) {
    my $head = $lim < CORE::length($u) ? substr( $u, 0, $lim ) : $u;
    return [ split //, $head ];
  }
  return [$s] if $u eq '';

  my $r     = $self->_js_to_units($separator);
  my $r_len = CORE::length($r);
  my @parts;
  my $i = 0;
  my $j = index( $u, $r, 0 );
  while ( $j != -1 ) {
    push @parts, $self->_js_unit_range( $u, $i, $j );
    return \@parts if @parts == $lim;
    $i = $j + $r_len;
    $j = index( $u, $r, $i );
  }
  push @parts, $self->_js_unit_range( $u, $i, CORE::length($u) );
  return \@parts;
}

#### js_string_compare -- the code-unit order of the JS relational operators

# IsLessThan on two strings compares UTF-16 code units, so U+FF01 sorts after
# U+1F600 (high surrogate U+D83D) where code points would put it before. cmp
# over the unit forms is exactly that order. Returns -1, 0 or 1.
sub js_string_compare {
  my ( $self, $x, $y ) = @_;
  return $self->_js_to_units($x) cmp $self->_js_to_units($y);
}

1;
