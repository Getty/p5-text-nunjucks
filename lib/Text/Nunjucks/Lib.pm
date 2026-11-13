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
# Circular with Runtime's `use Text::Nunjucks::Lib`; map's array-like branch
# and groupBy's result object (make_dict) are the Lib calls up into it -- from
# inside their subs, run time. Caveat: when Lib loads first,
# this line compiles and runs all of Runtime before the rest of Lib is even
# compiled -- the Lib subs below this line do not exist yet and its file-scope
# lexicals (%ESCAPE_MAP, $JS_WORD_CLASS, $NUM_POS_INF, ...) are still unset. So
# Runtime must never call a Lib function at file scope (a `my $X = Lib->...`,
# a BEGIN, a `use constant`); calls from inside its subs are fine.
use Text::Nunjucks::Runtime;

no warnings 'experimental::builtin';

# lib.js is a plain bag of exported functions accessed qualified as `lib.foo`.
# Ported as a class-method-only module (getty-perl-core "dispatch through the
# invocant"): every function is a method taking $self, callers use
# Text::Nunjucks::Lib->is_array($x), cross-calls go through $self. No instances.
# ADR 0001 designates this module the single home for value-kind checks.

# The collaborator class, named once (getty-perl-core resolver), for map's
# array-like branch and groupBy's engine-built result.
sub _runtime { 'Text::Nunjucks::Runtime' }

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
  # Object.prototype.toString.call(obj) === '[object Object]': a plain hashref,
  # an ordered dict (template literal / engine-built object, ADR 0011) and a
  # SafeString -- a String subclass whose instances are ordinary objects
  # (oracle: '{% macro m() %}ab{% endmacro %}' m()|list gives val=ab;length=2;).
  # Other blessed objects are k6/Runtime member-access territory.
  return 1 if ref($obj) eq 'HASH';
  return ( blessed($obj) && ( $obj->isa('Hash::Ordered') || $obj->isa('Text::Nunjucks::Runtime::SafeString') ) )
    ? 1 : 0;
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
  # const result = {} -- an engine-built object, so an ordered dict from
  # Runtime's make_dict (ADR 0011): groups iterate in JS key order
  my $result   = $self->_runtime->make_dict;
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
    # (result[key] || (result[key] = [])).push(value)
    push @{ $result->get($hkey) // $result->set( $hkey, [] ) }, $value;
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
  # if (obj == null) -- undefined here; null (Runtime's None) after the array
  # branch, which so needs nothing from Runtime
  return $results if !defined $obj;

  # if (ArrayProto.map && obj.map === ArrayProto.map) return obj.map(func);
  # -- a real array; native Array.map passes (element, index, array)
  if ( $self->is_array($obj) ) {
    for my $i ( 0 .. $#$obj ) {
      $results->[$i] = $func->( $obj->[$i], $i, $obj );
    }
    return $results;
  }

  # Anything else is read as an array-like. obj.length and obj[i] are JS
  # property reads and `i < obj.length` a JS comparison: Runtime's
  # member_lookup and op_lt, the one home of both (ADR 0008 / 0007), so this
  # branch calls up into Runtime (as groupBy does for make_dict). Oracle: a
  # SafeString has a length but no index access ('abc' from a macro, |reverse
  # -> ',,'), {length: '2', 0: 'x', 1: 'y'} maps x, y, a number or a plain
  # object without length maps nothing. A primitive string cannot change under
  # the loop, so it is read through its split('') units -- the same length and
  # the same obj[i] (ADR 0012) without measuring the string once per index.
  my $rt = $self->_runtime;
  return $results if $rt->_is_none($obj);
  my $array_like = $self->is_string($obj) ? $self->js_split( $obj, '' ) : $obj;

  for ( my $i = 0; $rt->op_lt( $i, $rt->member_lookup( $array_like, 'length' ) ); $i++ ) {
    $results->[ scalar @$results ] = $func->( $rt->member_lookup( $array_like, $i ), $i );
  }

  # if (obj.length === +obj.length) results.length = obj.length; -- setting an
  # array's length to anything but an integer in [0, 2^32 - 1] is a RangeError
  # (oracle: {length: 2.5}|reverse, {length: -1}|reverse)
  my $length = $rt->member_lookup( $array_like, 'length' );
  if ( $self->_strict_eq( $length, $rt->op_pos($length) ) ) {
    die Text::Nunjucks::Lib::Error->new( 'Invalid array length', name => 'RangeError' )
      if $self->_js_to_uint32($length) != $length;
    $#$results = $length - 1;
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
  # a plain hashref reads via ->{}. asyncFor doesn't reach Runtime->member_lookup
  # (Lib calls up into Runtime only in map and groupBy),
  # so this is the single seam -- the Runtime side mirrors it for its own
  # async_all loop.
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
  # own enumerable keys. ADR 0011 (amended on k51) sets the ordering policy in
  # one place:
  #
  #   * Hash::Ordered (template dict literal / engine-built object): own keys
  #     in JS order -- _ordinary_own_property_keys over its insertion order,
  #     byte-identical to JS Object.keys.
  #   * Plain caller hash: the array-index keys first, ascending, then the
  #     rest key-sorted -- the documented divergence is only in that rest
  #     (Perl hashes carry no insertion order to preserve; sorted gives a
  #     deterministic cross-PERL_HASH_SEED iteration where JS would have shown
  #     insertion order).
  #
  # _entries / _values / extend / async_for / member_lookup / the dump /
  # dictsort / list / items filters (k17) all reach the iterator here, so this
  # is the only seam the policy needs.
  #
  # Non-hash refs are an open latency: JS keys([10,20]) -> ['0','1'], but a
  # non-HASH ref dies here on the deref. The value model routes arrays through
  # async_iter / to_array, so this is believed unreachable; keys(undef) already
  # yields [] cleanly. Revisit if a k14/k17 call site reaches it.
  #
  # for-in over undefined, null, a number, a boolean or a function enumerates
  # nothing (oracle: 5|urlencode, none|urlencode and a macro|urlencode render
  # '' -- lib._entries(obj) is []). A primitive string's indices are k59.
  return [] if !defined($obj) || ( !ref($obj) && !$self->is_string($obj) );
  return [] if $self->_runtime->_is_none($obj) || $self->is_function($obj);
  return $self->_ordinary_own_property_keys( [ $obj->keys ] ) if blessed($obj) && $obj->isa('Hash::Ordered');

  # A SafeString (engine-built): its own properties in the order its
  # constructor creates them, this.val then this.length.
  return [ 'val', 'length' ] if blessed($obj) && $obj->isa('Text::Nunjucks::Runtime::SafeString');

  # Plain hash: sort CORE::keys (per-process-random Perl order) deterministically.
  my $arr = [];
  for my $k ( sort CORE::keys %$obj ) {
    push @$arr, $k if $self->has_own_prop( $obj, $k );
  }
  return $self->_ordinary_own_property_keys($arr);
}

# Port addition (ADR 0011, k51): the order JS's for-in gives an ordinary
# object's own string keys, ECMAScript OrdinaryOwnPropertyKeys -- every array
# index first, in ascending numeric order, then the other keys in the order
# given (insertion order for an ordered dict, key-sorted for a plain hash).
# oracle: {"a":1,"10":2,"9":3,"01":4,"-1":5,"4294967295":6,"4294967294":7,"1.5":8}
# iterates 9;10;4294967294;a;01;-1;4294967295;1.5;
sub _ordinary_own_property_keys {
  my ( $self, $keys ) = @_;
  my ( @index, @rest );
  for my $k (@$keys) {
    if ( $self->_is_array_index($k) ) { push @index, $k }
    else                               { push @rest,  $k }
  }
  return [ ( sort { $a <=> $b } @index ), @rest ];
}

# An array index is a String P with ToString(ToUint32(P)) === P and
# ToUint32(P) !== 2^32 - 1: the canonical ASCII decimal form of an integer
# 0 .. 4294967294. oracle: '0' and '4294967294' are indices; '4294967295',
# '00', '01', '-0', '-1', '+1', '1.5', '1e3', ' 1', '0x1', '' and non-ASCII
# digits are not. At most ten digits pass the pattern; a ten-digit one is
# compared with 4294967294 as a string.
sub _is_array_index {
  my ( $self, $k ) = @_;
  return 0 unless $k =~ /\A(?:0|[1-9][0-9]{0,9})\z/;
  return ( length($k) < 10 || $k le '4294967294' ) ? 1 : 0;
}

#### _entries

sub _entries {
  my ( $self, $obj ) = @_;
  return [ CORE::map { [ $_, $self->_own_value( $obj, $_ ) ] } @{ $self->keys($obj) } ];
}

#### _values

sub _values {
  my ( $self, $obj ) = @_;
  return [ CORE::map { $self->_own_value( $obj, $_ ) } @{ $self->keys($obj) } ];
}

# obj[k] for a key keys() returned: an ordered dict (a blessed array, ADR 0011)
# reads through ->get, a hash -- a SafeString's included -- by its key.
sub _own_value {
  my ( $self, $obj, $k ) = @_;
  return ( blessed($obj) && $obj->isa('Hash::Ordered') ) ? $obj->get($k) : $obj->{$k};
}

#### extend / _assign

sub extend {
  my ( $self, $obj1, $obj2 ) = @_;
  $obj1 = {} unless $obj1;    # JS obj1 || {} (obj1 is hashref|undef; refs are truthy)
  for my $k ( @{ $self->keys($obj2) } ) {
    $obj1->{$k} = $self->_own_value( $obj2, $k );
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
# \w is js_word_class and \d js_digit_class below (ADR 0005: added on demand,
# one seam per class, like _strict_eq / _falsy below).
my $JS_WHITESPACE_CLASS =
  qr/[\x09\x0A\x0B\x0C\x0D\x20\x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]/u;

sub js_whitespace_class {
  my ($self) = @_;
  return $JS_WHITESPACE_CLASS;
}

# JavaScript's \w is [A-Za-z0-9_] -- ASCII only, without the u flag and with it
# (only u together with i widens it). Perl's \w is Unicode word characters. The
# filters' own regexes (wordcount's /\w+/g, striptags' \b) use this set; oracle:
# 'héllo wörld'|wordcount is 4, '١٢٣ abc'|wordcount is 1, and striptags keeps
# '<ab_c>' (no \b between b and _) but strips '<aſb>' (ſ is not a word char).
my $JS_WORD_CLASS = qr/[A-Za-z0-9_]/;

sub js_word_class {
  my ($self) = @_;
  return $JS_WORD_CLASS;
}

# JavaScript's \d is [0-9] -- ASCII only, with or without the u and i flags.
# Perl's \d is every Unicode decimal digit. urlize's emailRe uses it; oracle:
# 'a@x\u0663.com'|urlize does not take the mailto: branch (ARABIC-INDIC DIGIT
# THREE is not \d), 'a@x3.com' does.
my $JS_DIGIT_CLASS = qr/[0-9]/;

sub js_digit_class {
  my ($self) = @_;
  return $JS_DIGIT_CLASS;
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
my $NUM_POS_INF  = 9**9**9;
my $NUM_NEG_INF  = -$NUM_POS_INF;
my $NUM_NAN      = $NUM_POS_INF - $NUM_POS_INF;
my $NUM_NEG_ZERO = -0.0;

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

#### js_math_floor -- Math.floor(x)

# Not a src/lib.js function: the filters' Math.floor (random, slice), over an
# already-ToNumber'd value as the other number seams here take it. C's floor is
# IEEE's: NaN and +-Infinity pass through, -0 stays -0.
sub js_math_floor {
  my ( $self, $n ) = @_;
  return POSIX::floor($n);
}

#### js_math_ceil -- Math.ceil(x)

# The round filter's 'ceil' method, over an already-ToNumber'd value like
# js_math_floor: C's ceil is IEEE's, -0.5 gives -0.
sub js_math_ceil {
  my ( $self, $n ) = @_;
  return POSIX::ceil($n);
}

#### js_math_round -- Math.round(x)

# The round filter's default method, over an already-ToNumber'd value. The
# integral Number closest to x, a tie going towards +Infinity: 2.5 -> 3, -2.5 ->
# -2, and -0 for x in [-0.5, -0] (oracle: -0.5|round(0) is -0 -- 1/x is
# -Infinity). V8's Float64Round, step for step: ceil(x), one less unless ceil(x)
# - 0.5 <= x. It never computes x + 0.5, which rounds 0.49999999999999994 up to
# 1 and an odd integer above 2^52 to the next even one; NaN and +-Infinity pass
# through.
sub js_math_round {
  my ( $self, $n ) = @_;
  my $c = POSIX::ceil($n);
  return ( $c - 0.5 <= $n ) ? $c : $c - 1;
}

#### js_math_abs -- Math.abs(x)

# The abs filter (exports.abs = Math.abs), over an already-ToNumber'd value: C's
# fabs, so -0 is +0 and NaN stays NaN.
sub js_math_abs {
  my ( $self, $n ) = @_;
  return POSIX::fabs($n);
}

#### js_math_pow -- Math.pow(base, exponent)

# The round filter's Math.pow(10, precision) and the template ** operator
# (compiler.js emits Math.pow), over already-ToNumber'd values. Number::
# exponentiate is IEEE pow with two exceptions C's pow does not share: a NaN
# exponent gives NaN even for base 1, and base +-1 with an infinite exponent
# gives NaN, not 1 (oracle: 1 ** (1/0) -> NaN).
sub js_math_pow {
  my ( $self, $base, $exponent ) = @_;
  return $NUM_NAN if $exponent != $exponent;
  return $NUM_NAN
    if ( $exponent == $NUM_POS_INF || $exponent == $NUM_NEG_INF ) && ( $base == 1 || $base == -1 );
  return POSIX::pow( $base, $exponent );
}

#### js_parse_int -- parseInt(string, radix)

# Not a src/lib.js function: the global parseInt the int filter calls, over an
# already-ToString'd string and an already-ToNumber'd radix (undef for JS
# undefined), as the other number seams here take their arguments. ECMAScript
# parseInt step by step: leading StrWhiteSpaceChar trimmed (js_whitespace_class),
# one sign, the radix through ToInt32 -- 0 means 10, or 16 after a 0x / 0X
# prefix, which radix 16 strips too; outside 2..36 is NaN -- then the longest
# prefix of radix digits, NaN when there is none, and a zero keeps its sign
# (oracle: '-0'|int is -0). The digits' value is computed as V8 computes it,
# which the spec leaves to the implementation beyond 2^53 (oracle-fuzzed):
#
#   * radix 10: correctly rounded, as V8's Strtod -- Perl's numification of the
#     digit string is (an exact integer below 2^64, else C's strtod);
#   * radix 2, 4, 8, 16, 32: correctly rounded, round-half-even on the bits, the
#     integer arithmetic of V8's InternalStringToIntDouble;
#   * any other radix: V8's HandleGenericCase -- 32-bit chunks folded in by a
#     double multiply and a double add, two roundings per chunk.
sub js_parse_int {
  my ( $self, $input_string, $radix ) = @_;
  my $ws = $self->js_whitespace_class;
  ( my $s = $input_string ) =~ s/\A(?:$ws)+//;    # TrimString(inputString, start)
  my $sign = 1;
  $sign = -1 if substr( $s, 0, 1 ) eq '-';
  $s = substr( $s, 1 ) if $s =~ /\A[+-]/;
  my $r            = $self->_js_to_int32($radix);
  my $strip_prefix = 1;
  if ( $r != 0 ) {
    return $NUM_NAN if $r < 2 || $r > 36;
    $strip_prefix = 0 if $r != 16;
  } else {
    $r = 10;
  }
  if ( $strip_prefix && $s =~ /\A0[xX]/ ) {
    $s = substr( $s, 2 );
    $r = 16;
  }
  # the radix-R digits: 0-9 then a-z / A-Z, ASCII only
  my $class = $r <= 10
    ? '0-' . ( $r - 1 )
    : '0-9a-' . chr( ord('a') + $r - 11 ) . 'A-' . chr( ord('A') + $r - 11 );
  my ($z) = $s =~ /\A([$class]*)/;
  return $NUM_NAN if $z eq '';
  my $math_int = $self->_js_parse_int_value( $z, $r );
  return $sign < 0 ? $NUM_NEG_ZERO : 0 if $math_int == 0;
  return $sign < 0 ? -$math_int : $math_int;
}

# The value of a non-empty string of radix-$r digits, as V8 computes it.
sub _js_parse_int_value {
  my ( $self, $z, $r ) = @_;
  $z =~ s/\A0+//;    # V8 skips leading zeros before it counts digits
  return 0 if $z eq '';
  if ( $r == 10 ) {
    # V8 keeps the first 310 significant digits; more than 309 is past the
    # largest double either way
    return unpack( 'd', pack( 'd', 0 + substr( $z, 0, 310 ) ) );
  }
  my @digits = CORE::map { /[0-9]/ ? ord($_) - ord('0') : ( ord( lc $_ ) - ord('a') + 10 ) } split //, $z;
  return $self->_js_parse_int_power_of_two( \@digits, $r ) if ( $r & ( $r - 1 ) ) == 0;
  return $self->_js_parse_int_generic( \@digits, $r );
}

# V8's InternalStringToIntDouble<radix_log_2>: accumulate the digits in an
# integer until it passes 53 bits, then round half to even on the bits dropped,
# a non-zero tail breaking a tie upwards, and scale by the bits left over.
sub _js_parse_int_power_of_two {
  my ( $self, $digits, $radix ) = @_;
  my $radix_log_2 = 0;
  $radix_log_2++ while ( 1 << $radix_log_2 ) < $radix;
  my $number   = 0;    # an exact integer, below 2^58 (Perl IVs are 64-bit)
  my $exponent = 0;
  for ( my $i = 0; $i < @$digits; $i++ ) {
    $number = $number * $radix + $digits->[$i];
    my $overflow = $number >> 53;
    if ( $overflow != 0 ) {
      # Overflow occurred. Need to determine which direction to round the result.
      my $overflow_bits_count = 1;
      while ( $overflow > 1 ) {
        $overflow_bits_count++;
        $overflow >>= 1;
      }

      my $dropped_bits_mask = ( 1 << $overflow_bits_count ) - 1;
      my $dropped_bits      = $number & $dropped_bits_mask;
      $number >>= $overflow_bits_count;
      $exponent = $overflow_bits_count;

      my $zero_tail = 1;
      for ( $i++; $i < @$digits; $i++ ) {
        $zero_tail = 0 if $digits->[$i] != 0;
        $exponent += $radix_log_2;
      }

      my $middle_value = 1 << ( $overflow_bits_count - 1 );
      if ( $dropped_bits > $middle_value ) {
        $number++;    # Rounding up.
      } elsif ( $dropped_bits == $middle_value ) {
        # Rounding to even to consistency with decimals: half-way case rounds
        # up if significant part is odd and down otherwise.
        $number++ if ( $number & 1 ) != 0 || !$zero_tail;
      }

      # Rounding up may cause overflow.
      if ( ( $number & ( 1 << 53 ) ) != 0 ) {
        $exponent++;
        $number >>= 1;
      }
      last;
    }
  }
  return unpack( 'd', pack( 'd', $number ) ) if $exponent == 0;
  return POSIX::ldexp( $number, $exponent );
}

# V8's HandleGenericCase: the digits in chunks whose multiplier stays below
# 0xFFFFFFFF / 36, each folded in as result * multiplier + part in double
# arithmetic -- every step through pack('d'), since Perl would otherwise keep an
# exact integer product where the double rounds.
sub _js_parse_int_generic {
  my ( $self, $digits, $radix ) = @_;
  my $maximum_multiplier = int( 0xFFFFFFFF / 36 );
  my $result             = 0;
  my $i                  = 0;
  my $done               = 0;
  while ( !$done ) {
    my ( $part, $multiplier ) = ( 0, 1 );
    while (1) {
      if ( $i >= @$digits ) {
        $done = 1;
        last;
      }
      my $m = $multiplier * $radix;
      last if $m > $maximum_multiplier;
      $part       = $part * $radix + $digits->[$i];
      $multiplier = $m;
      $i++;
    }
    $result = unpack( 'd', pack( 'd', $result * $multiplier ) );
    $result = unpack( 'd', pack( 'd', $result + $part ) );
  }
  return $result;
}

#### js_parse_float -- parseFloat(string)

# Not a src/lib.js function: the global parseFloat the float filter calls, over
# an already-ToString'd string. Leading StrWhiteSpaceChar trimmed, then the
# longest prefix that is a StrDecimalLiteral -- an optional sign, then Infinity
# or digits with an optional fraction and exponent, no 0x, no numeric separator
# -- else NaN (oracle: '3.7abc' -> 3.7, '.5' -> 0.5, '1e' -> 1, 'Infinityx' ->
# Infinity, 'infinity' -> NaN, '-0' -> -0). The value is the correctly rounded
# double, as V8's StringToDouble gives it; Perl numifies a decimal string through
# C's strtod, which rounds correctly too.
sub js_parse_float {
  my ( $self, $input_string ) = @_;
  my $ws = $self->js_whitespace_class;
  ( my $s = $input_string ) =~ s/\A(?:$ws)+//;    # TrimString(inputString, start)
  my ( $sign, $unsigned ) =
    $s =~ /\A([+-]?)(Infinity|(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)/
    or return $NUM_NAN;
  my $n = $unsigned eq 'Infinity' ? $NUM_POS_INF : unpack( 'd', pack( 'd', 0 + $unsigned ) );
  return $n if $sign ne '-';
  return $n == 0 ? $NUM_NEG_ZERO : -$n;
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
# Runtime (ADR 0007) and these seams do not call into Runtime: an argument is a JS
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

# ECMAScript ToInt32 over an already-ToNumber'd value (parseInt's radix), undef
# being JS undefined: ToUint32, then the upper half of the range wraps negative.
sub _js_to_int32 {
  my ( $self, $n ) = @_;
  return 0 unless defined $n;
  my $m = $self->_js_to_uint32($n);
  return $m >= 2147483648 ? $m - 4294967296 : $m;
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

#### js_to_lower_case / js_to_upper_case -- String.prototype.toLowerCase / toUpperCase

# Not src/lib.js functions: the one home of JS case mapping, for the lower /
# upper / capitalize / title filters and the String methods a template calls.
# JS maps by code point with the full Unicode default case conversion -- the
# unconditional SpecialCasing mappings included (oracle: 'ß' upper is 'SS', 'İ'
# lower is 'i' + U+0307, two code units) -- which Perl's lc / uc also do, with
# two differences handled here:
#
#   * Final_Sigma, the one language-independent conditional mapping: a capital
#     sigma lowercases to final 'ς' where it ends a word, else to 'σ'. Perl's lc
#     always gives 'σ'. Oracle: 'ΑΣ' -> 'ας', 'ΑΣΑ' -> 'ασα', 'ΑΣ.' -> 'ας.',
#     'Α.Σ' -> 'α.ς', 'ΑΣ1' -> 'ας1', '1Σ' -> '1σ', 'ΑΣ\x{AD}' -> 'ας\x{AD}'.
#     The context test is ICU's, which V8 calls: skip case-ignorable characters
#     outward from the sigma, and the first other character must be cased
#     before it and must not be cased after it. A character that is both cased
#     and case-ignorable counts as ignorable (oracle: 'ʰΣ' -> 'ʰσ', U+02B0 is
#     both, where the Unicode wording alone would give 'ʰς').
#   * Perl maps Latin-1 characters by Unicode rules only under the
#     unicode_strings feature (else uc("\xDF") stays "\xDF" on a string without
#     the UTF-8 flag); both seams enable it.
#
# A lone surrogate maps to itself, as in JS (Perl would warn). A caller string
# that spells a pair as two surrogate characters is re-paired first, so both
# spellings map alike.
my $JS_FINAL_SIGMA = qr/
  ( (?!\p{Case_Ignorable})\p{Cased} \p{Case_Ignorable}* )    # the cased letter before
  \x{3A3}
  (?! \p{Case_Ignorable}* (?!\p{Case_Ignorable})\p{Cased} )  # no cased letter after
/x;

sub js_to_lower_case {
  my ( $self, $s ) = @_;
  use feature 'unicode_strings';
  no warnings 'surrogate';
  $s = $self->_js_from_units($s);
  $s =~ s/$JS_FINAL_SIGMA/$1\x{3C2}/g if index( $s, "\x{3A3}" ) >= 0;
  return lc $s;
}

sub js_to_upper_case {
  my ( $self, $s ) = @_;
  use feature 'unicode_strings';
  no warnings 'surrogate';
  return uc $self->_js_from_units($s);
}

#### js_get_substitution -- GetSubstitution, the replacement patterns of replace

# Not a src/lib.js function: ECMAScript GetSubstitution(matched, str, position,
# captures, namedCaptures, replacement), which String.prototype.replace and
# RegExp.prototype[Symbol.replace] apply to a string replacement:
#
#   $$ -> '$'   $& -> matched   $` -> str before the match   $' -> str after it
#   $n / $nn    -> capture n (1..99), '' for a group that did not take part; a
#                  two-digit index past the last group is read as one digit and a
#                  literal digit ($10 with one group -> capture 1 then '0'), and an
#                  index of 0 or past the groups stays literal ($0, $00, $1 with none)
#   $<name>     -> the named group ('' if absent); literal '$<' when the regex has
#                  no named groups ($named undef) or no '>' follows; $named is
#                  the match's groups object, an engine-built Hash::Ordered
#
# Oracle: 'abc'.replace(/(b)/, '[$1$2$0$01$10]') -> 'a[b$2$0bb0]c'; with eleven
# groups '[$11|$10|$1|$12|$011|$00|$100]' -> '[k|j|a|a2|a1|$00|j0]'. $position
# counts code units (ADR 0012); $captures is an arrayref (undef for a group that
# did not participate); every piece is joined through js_string_append.
sub js_get_substitution {
  my ( $self, $matched, $str, $position, $captures, $named, $replacement ) = @_;
  return $replacement if index( $replacement, '$' ) < 0;

  my $m      = scalar @$captures;
  my $result = '';
  pos($replacement) = 0;
  while ( pos($replacement) < CORE::length($replacement) ) {
    my $ref_replacement;
    if ( $replacement =~ /\G([^\$]+)/gc ) {
      $ref_replacement = $1;
    } elsif ( $replacement =~ /\G\$\$/gc ) {
      $ref_replacement = '$';
    } elsif ( $replacement =~ /\G\$`/gc ) {
      $ref_replacement = $self->js_substring( $str, 0, $position );
    } elsif ( $replacement =~ /\G\$&/gc ) {
      $ref_replacement = $matched;
    } elsif ( $replacement =~ /\G\$'/gc ) {
      my $tail_pos = $position + $self->js_string_length($matched);
      $ref_replacement = $self->js_substring( $str, $tail_pos );    # substring clamps to the length
    } elsif ( $replacement =~ /\G\$([0-9])([0-9]?)/gc ) {
      my ( $d1, $d2 ) = ( $1, $2 );
      my $index = $d1 . $d2;
      if ( $d2 ne '' && $index > $m ) {
        # a two-digit index past the groups: one digit, the second is literal
        ( $index, $d2 ) = ( $d1, '' );
        pos($replacement) = pos($replacement) - 1;
      }
      $ref_replacement = ( $index >= 1 && $index <= $m )
        ? ( defined( $captures->[ $index - 1 ] ) ? $captures->[ $index - 1 ] : '' )
        : '$' . $d1 . $d2;
    } elsif ( $replacement =~ /\G\$</gc ) {
      my $gt_pos = index( $replacement, '>', pos($replacement) );
      if ( $gt_pos < 0 || !defined($named) ) {
        $ref_replacement = '$<';
      } else {
        my $group_name = substr( $replacement, pos($replacement), $gt_pos - pos($replacement) );
        pos($replacement) = $gt_pos + 1;
        my $capture = $named->get($group_name);
        $ref_replacement = defined($capture) ? $capture : '';
      }
    } else {
      $replacement =~ /\G\$/gc;
      $ref_replacement = '$';
    }
    $self->js_string_append( $result, $ref_replacement );
  }
  return $result;
}

#### js_encode_uri_component -- encodeURIComponent(uriComponent)

# Not a src/lib.js function: the global encodeURIComponent the urlencode filter
# calls, over an already-ToString'd string. ECMAScript Encode(string,
# extraUnescaped): A-Z a-z 0-9 and - _ . ! ~ * ' ( ) stay, every other code
# point goes out as the %XX bytes of its UTF-8 form in uppercase hex (oracle:
# 'a b&c' -> a%20b%26c, 'é' -> %C3%A9, '\u{1F600}' -> %F0%9F%98%80). It walks code
# units: a surrogate pair is the one code point, a lone surrogate has no UTF-8
# form and throws URIError: URI malformed (oracle: '\u{1F600}'|first|urlencode). A
# caller string spelling a pair as two surrogate characters is re-paired first,
# so both spellings encode alike (ADR 0012).
sub js_encode_uri_component {
  my ( $self, $s ) = @_;
  my $str = $self->_js_from_units($s);
  die Text::Nunjucks::Lib::Error->new( 'URI malformed', name => 'URIError' )
    if $str =~ /[\x{D800}-\x{DFFF}]/;
  return $str =~ s{([^A-Za-z0-9\-_.!~*'()])}{$self->_js_utf8_percent_encode($1)}ger;
}

sub _js_utf8_percent_encode {
  my ( $self, $char ) = @_;
  utf8::encode($char);
  return CORE::join( '', CORE::map { sprintf( '%%%02X', ord $_ ) } split //, $char );
}

1;
