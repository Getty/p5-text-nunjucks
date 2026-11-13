#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use builtin qw( true false is_bool );

no warnings 'experimental::builtin';

# Perl-side unit tests for Text::Nunjucks::Lib (port of src/lib.js). lib.js is
# foundation utility code exercised end-to-end only through filters/runtime/
# render (not yet ported), so it has no direct upstream .t counterpart and is
# not replayed by the corpus harness. Values that depend on JS semantics
# (escape output, prettified error messages) were confirmed with maint/oracle.js
# and are pinned here; the rest are structural Perl-API assertions.

use_ok('Text::Nunjucks::Lib');
use_ok('Text::Nunjucks::Lib::TemplateError');
use_ok('Text::Nunjucks::Lib::Error');

use_ok('Hash::Ordered');

my $L = 'Text::Nunjucks::Lib';

#### escape / lookupEscape  (oracle-confirmed: & " ' < > and backslash; backtick NOT escaped)

subtest 'escape' => sub {
  # input:  a&b"c'd<e>f\g`h   (context s in maint/oracle.js probe)
  my $in  = q{a&b"c'd<e>f\g`h};
  my $exp = q{a&amp;b&quot;c&#39;d&lt;e&gt;f&#92;g`h};
  is( $L->escape($in), $exp, 'all five entities plus backslash, backtick left alone' );
  is( $L->escape(q{&<>'"}), q{&amp;&lt;&gt;&#39;&quot;}, 'literal escape order' );
  is( $L->escape('plain text'), 'plain text', 'no-op on plain text' );

  is( $L->lookup_escape('&'),  '&amp;',  'lookup &' );
  is( $L->lookup_escape('\\'), '&#92;',  'lookup backslash' );
  is( $L->lookup_escape('`'),  undef,    'backtick not in map' );
};

#### kind checks (ADR 0001)

subtest 'is_function / is_array / is_object' => sub {
  ok( $L->is_function( sub { } ), 'coderef is a function' );
  ok( !$L->is_function(5),        'number is not a function' );

  ok( $L->is_array( [ 1, 2 ] ), 'arrayref is an array' );
  ok( !$L->is_array( {} ),      'hashref is not an array' );
  ok( !$L->is_array(5),         'number is not an array' );

  ok( $L->is_object( {} ),        'hashref is an object' );
  ok( !$L->is_object( [] ),       'arrayref is not an object' );
  ok( !$L->is_object('x'),        'string is not an object' );
  # oracle: {{ {b: 1, a: 2}|list }} iterates b, a -- a dict literal is a plain object
  ok( $L->is_object( Hash::Ordered->new( a => 1 ) ), 'an ordered dict (ADR 0011) is an object' );
  ok( !$L->is_object( bless {}, 'TN_Lib_Other' ),   'another blessed object is not' );
};

subtest 'is_string (ADR 0001 kinds)' => sub {
  ok( $L->is_string('5'),  'numeric string is a string' );
  ok( $L->is_string(''),   'empty string is a string' );
  ok( !$L->is_string(5),   'number is not a string' );
  ok( !$L->is_string(true), 'boolean is not a string' );
  ok( !$L->is_string(undef), 'undef is not a string' );
  ok( !$L->is_string( [] ),  'arrayref is not a string' );
};

#### hasOwnProp

subtest 'has_own_prop' => sub {
  ok( $L->has_own_prop( { a => 1 }, 'a' ), 'hash: present key' );
  ok( !$L->has_own_prop( { a => 1 }, 'b' ), 'hash: absent key' );
  ok( $L->has_own_prop( [ 10, 20 ], '0' ), 'array: index 0' );
  ok( $L->has_own_prop( [ 10, 20 ], 1 ),   'array: index 1' );
  ok( !$L->has_own_prop( [ 10, 20 ], 2 ),  'array: out-of-range index' );
  ok( !$L->has_own_prop( 'scalar', 'x' ),  'non-container: false' );
};

#### _prepareAttributeParts -- exercises the JS "'0' is truthy" trap

subtest '_prepare_attribute_parts' => sub {
  is_deeply( $L->_prepare_attribute_parts('a.b.c'), [qw( a b c )], 'dotted path' );
  is_deeply( $L->_prepare_attribute_parts('x'),     ['x'],         'single part' );
  is_deeply( $L->_prepare_attribute_parts(undef),   [],            'undef -> empty' );
  is_deeply( $L->_prepare_attribute_parts(''),      [],            'empty string -> empty' );
  is_deeply( $L->_prepare_attribute_parts(0),       [],            'number 0 is falsy in JS -> empty' );
  is_deeply( $L->_prepare_attribute_parts('0'),     ['0'],         "string '0' is TRUTHY in JS -> ['0']" );
};

#### _falsy -- the isolated JS !x seam (F4), keyed to ADR 0001 kinds

subtest '_falsy (JS !x)' => sub {
  ok( $L->_falsy(undef),  'undef is falsy' );
  ok( $L->_falsy(0),      'number 0 is falsy' );
  ok( $L->_falsy(''),     'empty string is falsy' );
  ok( $L->_falsy(false),  'boolean false is falsy' );
  ok( !$L->_falsy('0'),   "string '0' is TRUTHY in JS (Perl disagrees)" );
  ok( !$L->_falsy(1),     'number 1 is truthy' );
  ok( !$L->_falsy('x'),   'non-empty string is truthy' );
  ok( !$L->_falsy(true),  'boolean true is truthy' );
  ok( !$L->_falsy( [] ),  'arrayref is truthy' );
  ok( !$L->_falsy( {} ),  'hashref is truthy' );
};

#### getAttrGetter

subtest 'get_attr_getter' => sub {
  my $g = $L->get_attr_getter('a.b');
  is( $g->( { a => { b => 42 } } ), 42, 'nested lookup' );
  is( $g->( { a => {} } ), undef, 'missing leaf -> undef' );
  is( $g->( { x => 1 } ),  undef, 'missing branch -> undef' );

  my $id = $L->get_attr_getter(undef);
  is_deeply( $id->( { a => 1 } ), { a => 1 }, 'empty parts -> identity' );
};

#### groupBy

subtest 'group_by' => sub {
  my $items = [ { k => 'x', n => 1 }, { k => 'y', n => 2 }, { k => 'x', n => 3 } ];
  my $grouped = $L->group_by( $items, 'k' );
  is( scalar( @{ $grouped->{x} } ), 2, 'two items under x' );
  is( scalar( @{ $grouped->{y} } ), 1, 'one item under y' );
  is( $grouped->{x}[1]{n}, 3, 'preserves item order within a group' );

  my $with_undef = $L->group_by( [ { k => 'a' }, {} ], 'k' );
  ok( exists $with_undef->{undefined}, 'undefined key coerces to "undefined"' );

  my $by_fn = $L->group_by( [ 1, 2, 3, 4 ], sub { $_[0] % 2 } );
  is_deeply( [ sort keys %$by_fn ], [ 0, 1 ], 'function iterator groups by return value' );

  my $err;
  eval { $L->group_by( [ {} ], 'k', true ); 1 } or $err = $@;
  ok( ref($err) && $err->isa('Text::Nunjucks::Lib::Error'), 'throwOnUndefined dies with an Error object' );
  is( $err->name, 'TypeError', 'error name is TypeError' );
  is( $err->message, 'groupby: attribute "k" resolved to undefined', 'error message text' );
};

#### toArray

subtest 'to_array' => sub {
  my $src = [ 1, 2, 3 ];
  my $cp  = $L->to_array($src);
  is_deeply( $cp, [ 1, 2, 3 ], 'copies contents' );
  isnt( $cp, $src, 'returns a new arrayref' );
  is_deeply( $L->to_array('ab'), [qw( a b )], 'string -> chars' );
  # node: Array.prototype.slice.call('a😀') -> ['a', '\ud83d', '\ude00']
  is_deeply( $L->to_array("a\x{1F600}"), [ 'a', "\x{D83D}", "\x{DE00}" ],
    'string -> UTF-16 code units, an astral char as two lone surrogates (ADR 0012)' );
};

#### without

subtest 'without' => sub {
  is_deeply( $L->without( [ 1, 2, 3, 2, 1 ], 2 ), [ 1, 3, 1 ], 'removes one value' );
  is_deeply( $L->without( [ 1, 2, 3 ], 2, 3 ), [1], 'removes several values' );
  is_deeply( $L->without( undef ), [], 'undef array -> empty' );
  is_deeply( $L->without( [qw( a b c )], 'b' ), [qw( a c )], 'strings' );
};

#### repeat

subtest 'repeat' => sub {
  is( $L->repeat( 'ab', 3 ), 'ababab', 'three times' );
  is( $L->repeat( 'x', 0 ),  '',       'zero times -> empty' );
  is( $L->repeat( 'x', -1 ), '',       'negative -> empty' );
  # F1 regression: JS `for (i=0; i<n; i++)` runs 3x for n=2.5, not Perl 1..$n's 2x.
  # Reached via center(): "test"|center(9) -> "  test   " uses repeat(' ', 2.5).
  is( $L->repeat( 'x',  2.5 ), 'xxx',  'fractional n runs the loop ceil times (F1)' );
  is( $L->repeat( 'ab', 1.5 ), 'abab', 'fractional n, multi-char' );
};

#### each

subtest 'each' => sub {
  my @seen;
  $L->each( [ 10, 20, 30 ], sub { my ( $v, $i ) = @_; push @seen, "$i:$v" } );
  is_deeply( \@seen, [ '0:10', '1:20', '2:30' ], 'callback gets value and index' );

  my @none;
  $L->each( undef, sub { push @none, 1 } );
  is_deeply( \@none, [], 'undef obj is a no-op' );
};

#### map

subtest 'map' => sub {
  is_deeply( $L->map( [ 1, 2, 3 ], sub { $_[0] * 2 } ), [ 2, 4, 6 ], 'maps values' );
  is_deeply(
    $L->map( [ 10, 20 ], sub { my ( $v, $i ) = @_; "$i:$v" } ),
    [ '0:10', '1:20' ],
    'callback gets index'
  );
  is_deeply( $L->map(undef, sub { }), [], 'undef obj -> empty' );
  my $arr = [ 1, 2 ];
  my @args;
  $L->map( $arr, sub { push @args, [@_] } );
  ok( $args[1][2] == $arr, 'native Array.map: the callback also gets the array' );
};

# The array-like branch reads obj.length / obj[i] and compares with JS < --
# Runtime's member_lookup and op_lt. Lib loads Runtime itself: this file loads
# only Lib, so no require here -- the subtest also pins that loading Lib alone
# suffices. Every value is oracle-grounded through upstream's
# lib.map(val, v => v), the reverse filter.
subtest 'map: array-likes, read through Runtime' => sub {
  my $R  = 'Text::Nunjucks::Runtime';
  my $id = sub { $_[0] };

  # oracle: {{ o|reverse|join(',') }} with o = {length: 2, 0: 'x', 1: 'y'} -> y,x;
  # with length '2' -> y,x; length '1.5' and [2] -> b,a; length true -> a
  is_deeply( $L->map( Hash::Ordered->new( length => 2, 0 => 'x', 1 => 'y' ), $id ), [qw( x y )], 'length and indices' );
  is_deeply( $L->map( { length => '2', 0 => 'x', 1 => 'y' }, $id ), [qw( x y )], 'a string length compares as a number' );
  is_deeply( $L->map( { length => '1.5', 0 => 'a', 1 => 'b' }, $id ), [qw( a b )], "'1.5': i < length twice, no length set" );
  is_deeply( $L->map( { length => [2], 0 => 'a', 1 => 'b' }, $id ), [qw( a b )], '[2] as length' );
  is_deeply( $L->map( { length => true, 0 => 'a' }, $id ), ['a'], 'true as length' );
  # oracle: {{ o|reverse|length }} with o = {key: 1, length: 5} -> 5 (all undefined)
  is_deeply( $L->map( { key => 1, length => 5 }, $id ), [ (undef) x 5 ], 'missing indices are undefined' );
  # oracle: '{% macro m() %}abc{% endmacro %}{{ m()|reverse }}' -> ,, -- a SafeString
  # has a length and no index access
  is_deeply( $L->map( $R->SafeString->new('abc'), $id ), [ (undef) x 3 ], 'a SafeString' );
  # oracle: {{ ('a😀b'|reverse).length }} -> 4 -- a string's code units
  {
    no warnings 'surrogate';
    is_deeply( $L->map( "a\x{1F600}b", $id ), [ 'a', "\x{D83D}", "\x{DE00}", 'b' ], 'a string maps its code units' );
  }
  # oracle: 5|reverse, {a: 1}|reverse, null|reverse -> nothing
  is_deeply( $L->map( 5, $id ),          [], 'a number has no length' );
  is_deeply( $L->map( { a => 1 }, $id ), [], 'an object without length' );
  is_deeply( $L->map( $R->None, $id ),   [], 'null (obj == null)' );

  my @args;
  $L->map( { length => 1, 0 => 'v' }, sub { push @args, [@_] } );
  is_deeply( \@args, [ [ 'v', 0 ] ], 'the callback gets (value, index)' );

  # oracle: {length: 2.5}|reverse and {length: -1}|reverse -> RangeError; {length: -0} -> nothing
  for my $length ( 2.5, -1 ) {
    my $err = eval { $L->map( { length => $length }, $id ); 1 } ? undef : $@;
    is( ref($err) ? $err->name . ': ' . $err->message : 'no error', 'RangeError: Invalid array length',
      "length $length: results.length = obj.length throws" );
  }
  is_deeply( $L->map( { length => -0.0 }, $id ), [], 'length -0' );
};

#### asyncIter / asyncFor  (CPS, ADR 0003 -- run synchronously here)

subtest 'async_iter' => sub {
  my @got;
  $L->async_iter(
    [ 1, 2, 3 ],
    sub { my ( $item, $i, $next, $cb ) = @_; push @got, $item; $next->(); },
    sub { push @got, 'done'; },
  );
  is_deeply( \@got, [ 1, 2, 3, 'done' ], 'iterates then calls cb' );
};

subtest 'async_for' => sub {
  my @got;
  $L->async_for(
    { a => 1 },
    sub { my ( $k, $v, $i, $len, $next ) = @_; push @got, "$k=$v", "len=$len"; $next->(); },
    sub { push @got, 'done'; },
  );
  is_deeply( \@got, [ 'a=1', 'len=1', 'done' ], 'iterates key/value then calls cb' );

  # JS `keys(arr || {})` -- a JS-falsy iterable (0, '', false, undef) must be an
  # empty loop, not a crash on deref. (F2; None is guarded upstream in Runtime.)
  for my $falsy ( 0, '', undef, false ) {
    my @none;
    my $ok = eval {
      $L->async_for( $falsy, sub { push @none, 1 }, sub { push @none, 'done' } );
      1;
    };
    ok( $ok, 'async_for on a falsy iterable does not crash' );
    is_deeply( \@none, ['done'], 'falsy iterable -> empty loop, cb still fires' );
  }
};

#### indexOf -- strict equality (===)

subtest 'index_of (strict ===)' => sub {
  is( $L->index_of( [ 1, 2, 3 ], 2 ), 1, 'finds a number' );
  is( $L->index_of( [ 1, 2, 3 ], 9 ), -1, 'absent -> -1' );
  is( $L->index_of( [ 'a', 'b' ], 'b' ), 1, 'finds a string' );
  is( $L->index_of( [ 1, 2, 3 ], '3' ), -1, "number 3 !== string '3'" );
  is( $L->index_of( [ '1', '2', '3' ], '3' ), 2, 'string matches string' );
  is( $L->index_of( [ 1, 2, 3, 2 ], 2, 2 ), 3, 'fromIndex skips earlier match' );
};

#### keys / _entries / _values  (order is the open k3 decision -> compare as sets)

subtest 'keys / _entries / _values' => sub {
  my $obj = { a => 1, b => 2 };
  is_deeply( [ sort @{ $L->keys($obj) } ], [qw( a b )], 'keys (as set)' );
  is_deeply(
    [ sort { $a->[0] cmp $b->[0] } @{ $L->_entries($obj) } ],
    [ [ 'a', 1 ], [ 'b', 2 ] ],
    '_entries (as set)'
  );
  is_deeply( [ sort @{ $L->_values($obj) } ], [ 1, 2 ], '_values (as set)' );

  my $ordered = Hash::Ordered->new( b => 1, a => 2 );
  is_deeply( $L->_entries($ordered), [ [ 'b', 1 ], [ 'a', 2 ] ], '_entries of an ordered dict reads its values' );
  is_deeply( $L->_values($ordered), [ 1, 2 ], '_values of an ordered dict' );
};

# oracle: '{% macro m() %}ab{% endmacro %}{% for p in m()|list %}{{ p.key }}={{ p.value }};{% endfor %}'
# -> val=ab;length=2; -- a SafeString's own properties in constructor order
subtest 'is_object / keys / _entries: a SafeString is an ordinary object' => sub {
  my $safe = Text::Nunjucks::Runtime->SafeString->new('ab');
  ok( $L->is_object($safe), 'is_object' );
  is_deeply( $L->keys($safe),     [qw( val length )], 'keys: this.val, then this.length' );
  is_deeply( $L->_entries($safe), [ [ 'val', 'ab' ], [ 'length', 2 ] ], '_entries' );
};

subtest 'keys over a primitive or a function enumerates nothing' => sub {
  # oracle: 5|urlencode, true|urlencode, none|urlencode, undefined|urlencode and
  # a macro|urlencode all render '' -- for-in over them yields no key
  is_deeply( $L->keys(undef),                           [], 'undefined' );
  is_deeply( $L->keys( Text::Nunjucks::Runtime->None ), [], 'null' );
  is_deeply( $L->keys(5),                               [], 'a number' );
  is_deeply( $L->keys(true),                            [], 'a boolean' );
  is_deeply( $L->keys( sub { } ),                       [], 'a function' );
};

# ADR 0011 -- ordering policy at the keys() seam. The "as set" assertions above
# cannot fail when the policy regresses, so pin the actual order here. Plain
# caller hashes are key-sorted (the documented divergence from JS insertion
# order); Hash::Ordered is honoured in its own order (template literals,
# engine-built objects).
subtest 'keys orders plain hashes key-sorted; Hash::Ordered in own order (ADR 0011)' => sub {
  # Insertion order on the Perl side is { b, a, c } -- with PERL_HASH_SEED off,
  # Perl's hash order is deterministic, but the canonical seed is on and the
  # sort here is what every consumer of Lib::keys depends on.
  my $plain = { b => 1, a => 2, c => 3 };
  is_deeply( $L->keys($plain), [qw( a b c )], 'plain hashref -> key-sorted' );

  # Reverse the insertion order to make sure it really is the keys' alphabetical
  # order, not Perl's hash-iteration accident.
  my $reversed = { z => 1, y => 2, m => 3 };
  is_deeply( $L->keys($reversed), [qw( m y z )], 'plain hashref -> key-sorted, second sample' );

  # Hash::Ordered is honoured in its own order.
  my $ordered = Hash::Ordered->new( b => 1, a => 2 );
  is_deeply( $L->keys($ordered), [qw( b a )], 'Hash::Ordered -> its own order' );

  # The seam's callers inherit the policy. async_for / _entries / _values /
  # extend / member_lookup all go through keys(); cover the first two directly.
  # async_for's iter callback is (k, val, i, len, next) -- 5 args; a shorter
  # destructure would bind $next to $len and crash on the first recursion.
  my @seen;
  $L->async_for(
    $plain,
    sub { my ( $k, $v, $i, $len, $next ) = @_; push @seen, "$k=$v"; $next->(); },
    sub { },
  );
  is_deeply( \@seen, [ 'a=2', 'b=1', 'c=3' ], 'async_for iterates plain hashref key-sorted' );

  is_deeply(
    $L->_entries($plain),
    [ [ 'a', 2 ], [ 'b', 1 ], [ 'c', 3 ] ],
    '_entries follows keys() -> key-sorted'
  );
  is_deeply( $L->_values($plain), [ 2, 1, 3 ], '_values follows keys() -> key-sorted' );
};

#### extend / _assign

subtest 'extend / _assign' => sub {
  my $a = { x => 1 };
  my $r = $L->extend( $a, { y => 2 } );
  is( $r, $a, 'returns and mutates the first hash' );
  is_deeply( $a, { x => 1, y => 2 }, 'merged' );

  is_deeply( $L->extend( undef, { z => 3 } ), { z => 3 }, 'undef target -> new hash' );

  is( $L->can('_assign'), $L->can('extend'), '_assign is an alias for extend' );
};

#### inOperator

subtest 'in_operator' => sub {
  ok( $L->in_operator( 'b', 'abc' ),      'substring in string' );
  ok( !$L->in_operator( 'z', 'abc' ),     'missing substring' );
  ok( $L->in_operator( 1, [ 1, 2 ] ),     'member of array' );
  ok( !$L->in_operator( '1', [ 1, 2 ] ),  "string '1' not === number 1 in array" );
  ok( $L->in_operator( 'a', { a => 1 } ), 'key of object' );
  ok( !$L->in_operator( 'z', { a => 1 } ), 'missing key' );

  ok( is_bool( $L->in_operator( 'b', 'abc' ) ), 'returns a boolean kind' );

  # F2 regression: JS "hello".indexOf(undefined) searches for "undefined" -> -1
  # -> false. Perl index() would turn undef into "" (matches at 0) and warn.
  ok( $L->in_operator( '', 'hello' ), 'empty string is a substring (present)' );
  my $warned = '';
  local $SIG{__WARN__} = sub { $warned .= $_[0] };
  ok( !$L->in_operator( undef, 'hello' ), 'undef key -> false, JS ToString "undefined" (F2)' );
  is( $warned, '', 'no uninitialized-value warning for undef key (F2)' );

  my $err;
  eval { $L->in_operator( 1, 2 ); 1 } or $err = $@;
  ok( ref($err) && $err->isa('Text::Nunjucks::Lib::Error'), 'unexpected type dies with an Error' );
  is( $err->name, 'Error', 'error name is Error' );
  is( $err->message, 'Cannot use "in" operator to search for "1" in unexpected types.', 'error text' );
};

#### TemplateError + _prettifyError  (messages oracle-confirmed)

subtest 'TemplateError.update' => sub {
  my $te = Text::Nunjucks::Lib::TemplateError->new( 'unknown block tag: foo', 1, 4 );
  is( $te->name,    'Template render error', 'fixed name' );
  is( $te->message, 'unknown block tag: foo', 'raw message before update (parse-mode shape)' );

  $te->update(undef);
  is(
    $te->message,
    "(unknown path) [Line 1, Column 4]\n  unknown block tag: foo",
    'first update adds path + [Line, Column] + 2-space indent'
  );

  my $no_pos = Text::Nunjucks::Lib::TemplateError->new('boom');
  $no_pos->update('page.njk');
  is( $no_pos->message, "(page.njk)\n  boom", 'no lineno -> no [Line] part' );

  my $nested = Text::Nunjucks::Lib::TemplateError->new( 'boom', 2, 5 );
  $nested->update('inner');
  $nested->update('outer');
  is(
    $nested->message,
    "(outer)\n (inner) [Line 2, Column 5]\n  boom",
    'second update: no [Line], single-space indent (include propagation)'
  );
};

subtest '_prettify_error' => sub {
  # foreign error (a JS-style Error) rendered exactly like the oracle
  my $raw = Text::Nunjucks::Lib::Error->new(
    'Cannot use "in" operator to search for "1" in unexpected types.' );
  my $pe = $L->_prettify_error( undef, 0, $raw );
  is( $pe->name, 'Template render error', 'wrapped error takes the render-error name' );
  is(
    $pe->message,
    qq{(unknown path)\n  Error: Cannot use "in" operator to search for "1" in unexpected types.},
    'wrap prepends "Error: " and the (unknown path) prefix'
  );

  # one of ours: not re-wrapped, just updated
  my $ours = Text::Nunjucks::Lib::TemplateError->new( 'unknown block tag: foo', 1, 4 );
  my $pe2  = $L->_prettify_error( 'tmpl.njk', 1, $ours );    # dev flag on -> keep object
  is( $pe2, $ours, 'existing TemplateError is updated in place (dev flag)' );
  is(
    $pe2->message,
    "(tmpl.njk) [Line 1, Column 4]\n  unknown block tag: foo",
    'update applied to our own error'
  );
};

#### JS string seams in UTF-16 code units (ADR 0012)

# The template-level behaviour is pinned by t/corpus/render-strings-utf16.json.
# What the corpus JSON cannot carry is a lone surrogate, so the seams' lone-
# surrogate results are asserted here (each confirmed in node), together with
# the Perl-side contract that a pair spelled as two surrogate characters and
# the astral character are the same JS string.
subtest 'UTF-16 code-unit seams: lone surrogates and both spellings of a pair' => sub {
  my $em     = "\x{1F600}";           # one Perl character, two UTF-16 code units
  my $halves = "\x{D83D}\x{DE00}";    # the same code units, spelled as two characters

  # node: '😀'.charAt(0) / charAt(1) -> '\ud83d' / '\ude00'
  is( $L->js_char_at( $em, 0 ), "\x{D83D}", 'js_char_at inside a pair -> its high surrogate' );
  is( $L->js_char_at( $em, 1 ), "\x{DE00}", 'js_char_at inside a pair -> its low surrogate' );
  # node: 'a😀b'.slice(1, 2) -> '\ud83d'; slice(1, 3) -> '😀'
  is( $L->js_string_slice( "a${em}b", 1, 2 ), "\x{D83D}", 'js_string_slice cutting a pair -> a lone surrogate' );
  is( $L->js_string_slice( "a${em}b", 1, 3 ), $em, 'a slice holding the whole pair comes back as the one character' );

  # node: ('\ud83d' + '\ude00').length -> 2, === '😀' -> true, '😀'.indexOf('\ude00') -> 1
  is( $L->js_string_length($halves), 2, 'js_string_length: two surrogate characters are two code units' );
  is( $L->js_string_compare( $halves, $em ), 0, 'js_string_compare: both spellings are the same string' );
  is( $L->js_string_slice( $halves, 0 ), $em, 'a seam result re-pairs a valid pair into the astral character' );
  is( $L->js_string_index_of( $em, "\x{DE00}" ), 1, 'js_string_index_of finds a lone surrogate inside a pair' );
};

# js_string_append is the one join of two strings (template ~ and +, concat,
# replace, Array join, the output buffer); render cases in the corpus cover
# those callers, this pins the seam itself, lone surrogates included.
subtest 'js_string_append: joins in place, re-pairs at the boundary only' => sub {
  my $em = "\x{1F600}";

  # node: '\ud83d' + '\ude00' === '😀' -> true; ('a\ud83d' + '\ude00b').length -> 4
  my $buf = "a\x{D83D}";
  $L->js_string_append( $buf, "\x{DE00}b" );
  is( $buf, "a${em}b", 'a lone high + lone low surrogate become the astral character' );
  is( CORE::length($buf), 3, '... as one Perl character' );

  my $plain = 'ab';
  is( $L->js_string_append( $plain, 'cd' ), undef, 'returns nothing' );
  is( $plain, 'abcd', 'appends to the caller variable in place' );

  # node: '\ud83d' + '\ud83d', '\ude00' + '\ude00', '\ude00' + '\ud83d' stay two units each
  for my $case (
    [ "\x{D83D}", "\x{D83D}", 'high + high' ],
    [ "\x{DE00}", "\x{DE00}", 'low + low' ],
    [ "\x{DE00}", "\x{D83D}", 'low + high' ],
    [ 'x',        "\x{DE00}", 'a non-surrogate + low' ],
    [ '',         "\x{DE00}", 'an empty buffer + low' ],
    [ "\x{D83D}", '',         'high + an empty string' ],
    [ "\x{D83D}", "x\x{DE00}", 'high + a string whose low surrogate is not first' ],
  ) {
    my ( $l, $r, $label ) = @$case;
    my $b = $l;
    $L->js_string_append( $b, $r );
    is( $b, $l . $r, "$label: plain concatenation" );
  }

  # node: ('\ude00\ud83d' + '\ude00\ud83d').length -> 4, with a valid pair in the middle
  my $lh = "\x{DE00}\x{D83D}";
  $L->js_string_append( $lh, "\x{DE00}\x{D83D}" );
  is( $lh, "\x{DE00}${em}\x{D83D}", 'only the pair at the seam joins; the outer halves stay lone' );
};

subtest 'repeat joins in code units' => sub {
  # node: lib.repeat('\ude00\ud83d', 2) -> de00 d83d de00 d83d, 3 code points
  is( $L->repeat( "\x{DE00}\x{D83D}", 2 ), "\x{DE00}\x{1F600}\x{D83D}",
    'the halves that meet between two repeats form the pair' );
};

#### JS case mapping -- js_to_lower_case / js_to_upper_case

subtest 'js_to_lower_case: Final_Sigma as ICU applies it' => sub {
  # oracle: {{ s | lower }} for each input; Case_Ignorable letters (U+00AD,
  # U+0301, U+0027, U+02B0) are skipped on both sides, a cased letter before
  # and none after makes the sigma final
  my @cases = (
    [ "\x{391}\x{3A3}",                         "\x{3B1}\x{3C2}",                         'ΑΣ -> ας' ],
    [ "\x{391}\x{3A3}.",                        "\x{3B1}\x{3C2}.",                        'before punctuation' ],
    [ "\x{391}\x{3A3}1",                        "\x{3B1}\x{3C2}1",                        'before a digit' ],
    [ "\x{3A3}",                                "\x{3C3}",                                'alone: not final' ],
    [ "\x{391}\x{3A3} \x{392}",                 "\x{3B1}\x{3C2} \x{3B2}",                 'before a space and a word' ],
    [ "\x{391}\x{3A3}\x{391}",                  "\x{3B1}\x{3C3}\x{3B1}",                  'inside a word' ],
    [ "\x{391}.\x{3A3}",                        "\x{3B1}.\x{3C2}",                        'after punctuation (Case_Ignorable)' ],
    [ "\x{391}\x{3A3}\x{AD}\x{391}",            "\x{3B1}\x{3C3}\x{AD}\x{3B1}",            'soft hyphen skipped after' ],
    [ "\x{391}\x{AD}\x{3A3}",                   "\x{3B1}\x{AD}\x{3C2}",                   'soft hyphen skipped before' ],
    [ "\x{391}\x{301}\x{3A3}\x{301}\x{391}",    "\x{3B1}\x{301}\x{3C3}\x{301}\x{3B1}",    'combining marks skipped' ],
    [ "1\x{3A3}",                               "1\x{3C3}",                               'after a digit: not final' ],
    [ "\x{391}'\x{3A3}'",                       "\x{3B1}'\x{3C2}'",                       'apostrophes skipped' ],
    [ "\x{1C5}\x{3A3}",                         "\x{1C6}\x{3C2}",                         'after a titlecase letter' ],
    [ "\x{2B0}\x{3A3}",                         "\x{2B0}\x{3C3}",                         'U+02B0 is cased and ignorable: not a cased letter before' ],
    [ "\x{391}\x{3A3}\x{3A3}",                  "\x{3B1}\x{3C3}\x{3C2}",                  'only the last of two' ],
    [ "\x{10400}\x{3A3}",                       "\x{10428}\x{3C2}",                       'after an astral cased letter' ],
    [ "\x{3A3}\x{10400}",                       "\x{3C3}\x{10428}",                       'before an astral cased letter' ],
    [ "\x{391}\x{3A3}\x{1F600}",                "\x{3B1}\x{3C2}\x{1F600}",                'before an emoji' ],
  );
  for my $case (@cases) {
    my ( $in, $want, $label ) = @$case;
    is( $L->js_to_lower_case($in), $want, $label );
  }
};

subtest 'js_to_upper_case / js_to_lower_case: special casing and encodings' => sub {
  # oracle: {{ s | upper }}, {{ s | lower }}, {{ ('İ' | lower) | length }} -> 2
  is( $L->js_to_upper_case("\x{DF}"), 'SS', 'ß -> SS' );
  is( $L->js_to_upper_case("\x{FB01}\x{149}\x{1F0}"), "FI\x{2BC}NJ\x{30C}", 'ﬁ ŉ ǰ expand' );
  is( $L->js_to_upper_case("\x{390}"), "\x{399}\x{308}\x{301}", 'ΐ expands to three' );
  is( $L->js_to_lower_case("\x{130}"), "i\x{307}", 'İ -> i + combining dot' );
  is( $L->js_to_upper_case("\x{1C5}"), "\x{1C4}", 'titlecase ǅ -> Ǆ' );
  is( $L->js_to_upper_case("\x{10428}\x{10400}"), "\x{10400}\x{10400}", 'astral Deseret upper' );
  is( $L->js_to_lower_case("\x{10428}\x{10400}"), "\x{10428}\x{10428}", 'astral Deseret lower' );

  # a native 8-bit string still maps by Unicode rules (unicode_strings)
  my $latin1 = "\xDF\xE9\xFF\xB5";
  ok( !utf8::is_utf8($latin1), 'the input is a native 8-bit string' );
  is( $L->js_to_upper_case($latin1), "SS\x{C9}\x{178}\x{39C}", 'ßéÿµ -> SSÉŸΜ' );
  is( $L->js_to_lower_case("\xC9\xDE"), "\x{E9}\x{FE}", 'ÉÞ -> éþ' );

  # ADR 0012: a lone surrogate maps to itself, two halves spelled as two
  # characters are the pair
  my @warnings;
  local $SIG{__WARN__} = sub { push @warnings, @_ };
  is( $L->js_to_upper_case("\x{D83D}"), "\x{D83D}", 'a lone high surrogate stays' );
  is( $L->js_to_lower_case("x\x{DE00}"), "x\x{DE00}", 'a lone low surrogate stays' );
  is( $L->js_to_upper_case("\x{D801}\x{DC28}"), "\x{10400}", 'a pair spelled as two halves maps as its character' );
  is_deeply( \@warnings, [], 'no surrogate warning' );
};

#### GetSubstitution -- js_get_substitution

subtest 'js_get_substitution: the JS replacement patterns' => sub {
  # oracle: 'abc'|replace(r/b/, ...) and the other templates cited per line;
  # the result here is what replaces the match, so 'a' . $result . 'c' is the
  # rendered output
  is( $L->js_get_substitution( 'b', 'abc', 1, [], undef, 'plain' ), 'plain', 'no $: as is' );
  is( $L->js_get_substitution( 'b', 'abc', 1, [], undef, q{[$&][$`][$'][$$][$][$x][$<n>][$1]} ),
    q{[b][a][c][$][$][$x][$<n>][$1]},
    q{$& $` $' $$; a lone $, $x, $<n> without groups and $1 without captures stay} );
  is( $L->js_get_substitution( 'b', 'abc', 1, ['b'], undef, q{[$1$2$0$01$10]} ), q{[b$2$0bb0]},
    'r/(b)/: $2 and $0 stay, $01 is $1, $10 is $1 then 0' );

  # 'abcdefghijkl'|replace(r/(a)(b)...(k)/, '[$11|$10|$1|$12|$011|$00|$100]')
  my @caps = map { chr( ord('a') + $_ ) } 0 .. 10;
  is( $L->js_get_substitution( 'abcdefghijk', 'abcdefghijkl', 0, \@caps, undef, q{[$11|$10|$1|$12|$011|$00|$100]} ),
    q{[k|j|a|a2|a1|$00|j0]}, 'two digits when the group exists, else one digit and a literal' );

  # 'ab'|replace(r/(a)|(z)/, '[$1|$2]') -> '[a|]b'
  is( $L->js_get_substitution( 'a', 'ab', 0, [ 'a', undef ], undef, q{[$1|$2]} ), q{[a|]},
    'a group that did not take part is empty' );

  # 'abc'|replace(r/(?<n>b)/, '[$<n>$<m>]') -> 'a[b]c'; '$<n' without '>' stays
  is( $L->js_get_substitution( 'b', 'abc', 1, ['b'], Hash::Ordered->new( n => 'b' ), q{[$<n>$<m>][$<n]} ),
    q{[b][$<n]}, 'named groups; an unknown name is empty, an unclosed one literal' );

  # '😀ab😀b'|replace(r/b/g, '[$`]') -> '😀a[😀a]😀[😀ab😀]': positions in code units
  is( $L->js_get_substitution( 'b', "\x{1F600}ab\x{1F600}b", 3, [], undef, q{[$`|$']} ),
    "[\x{1F600}a|\x{1F600}b]", '$` and $\' cut at a code-unit position' );
};

# oracle: [1,2,3,4,5]|slice(2.5) -> [[1,2],[3,4],[5]] (Math.floor(5 / 2.5) = 2);
# Math.floor on NaN, -0, +-Infinity and negatives as IEEE floor
subtest 'js_math_floor (Math.floor)' => sub {
  my $inf = 9**9**9;
  is( $L->js_math_floor(2.5),  2,  'positive fraction' );
  is( $L->js_math_floor(-2.5), -3, 'negative fraction rounds down' );
  is( $L->js_math_floor(3),    3,  'an integer is itself' );
  is( $L->number_to_string( $L->js_math_floor( $inf / $inf ) ), 'NaN',       'NaN' );
  is( $L->number_to_string( $L->js_math_floor($inf) ),          'Infinity',  'Infinity' );
  is( $L->number_to_string( $L->js_math_floor( -$inf ) ),       '-Infinity', '-Infinity' );
  is( sprintf( '%g', $L->js_math_floor(-0.0) ), '-0', '-0 stays -0' );
};

subtest 'js_word_class is ASCII' => sub {
  # oracle: 'héllo wörld'|wordcount -> 4, '١٢٣ abc'|wordcount -> 1
  my $w = $L->js_word_class;
  is( scalar( () = "h\x{E9}llo w\x{F6}rld" =~ /(?:$w)+/g ), 4, 'é and ö split words' );
  is( scalar( () = "\x{661}\x{662}\x{663} abc" =~ /(?:$w)+/g ), 1, 'Arabic-Indic digits are not word characters' );
  ok( '_' =~ /\A$w\z/, 'the underscore is' );
  ok( "\x{17F}" !~ /\A$w\z/, 'ſ is not' );
};

subtest 'js_digit_class is ASCII' => sub {
  # oracle: 'a@x3.com'|urlize is a mailto: link, the same with ARABIC-INDIC
  # DIGIT THREE (U+0663) for the 3 is not
  my $d = $L->js_digit_class;
  ok( '7' =~ /\A$d\z/,       'an ASCII digit is' );
  ok( "\x{663}" !~ /\A$d\z/, 'U+0663 is not' );
  ok( "\x{FF11}" !~ /\A$d\z/, 'FULLWIDTH DIGIT ONE is not' );
};

# Math.ceil / Math.round / Math.abs over a Number; oracle: 4.5|round is 5,
# -0.5|round(0) and -0.4|round(0, 'ceil') are -0 (1 / x is -Infinity), (-0)|abs
# is +0 (1 / x is Infinity)
subtest 'js_math_ceil / js_math_round / js_math_abs (Math.ceil, Math.round, Math.abs)' => sub {
  my $inf = 9**9**9;
  my $nan = $inf - $inf;
  my $s   = sub { $L->number_to_string( $_[0] ) };
  is( $L->js_math_ceil(2.1),  3,  'ceil: up' );
  is( $L->js_math_ceil(-2.9), -2, 'ceil: negative up' );
  is( sprintf( '%g', $L->js_math_ceil(-0.4) ), '-0', 'ceil: -0.4 is -0' );
  is( $s->( $L->js_math_ceil($nan) ), 'NaN', 'ceil: NaN' );

  is( $L->js_math_round(2.5),  3,  'round: a tie goes up' );
  is( $L->js_math_round(-2.5), -2, 'round: a negative tie goes towards +Infinity' );
  is( $L->js_math_round(2.4),  2,  'round: below the tie' );
  is( $L->js_math_round(0.49999999999999994), 0, 'round: the largest double below 0.5 is 0, never x + 0.5' );
  is( $s->( $L->js_math_round(4503599627370497) ), '4503599627370497', 'round: an odd integer above 2^52 is itself' );
  is( sprintf( '%g', $L->js_math_round(-0.5) ), '-0', 'round: -0.5 is -0' );
  is( sprintf( '%g', $L->js_math_round(-0.0) ), '-0', 'round: -0 stays -0' );
  is( $s->( $L->js_math_round($nan) ),    'NaN',       'round: NaN' );
  is( $s->( $L->js_math_round( -$inf ) ), '-Infinity', 'round: -Infinity' );

  is( $L->js_math_abs(-3.5), 3.5, 'abs' );
  is( sprintf( '%g', $L->js_math_abs(-0.0) ), '0', 'abs: -0 is +0' );
  is( $s->( $L->js_math_abs( -$inf ) ), 'Infinity', 'abs: -Infinity' );
  is( $s->( $L->js_math_abs($nan) ),    'NaN',      'abs: NaN' );
};

# Math.pow; oracle: 1 ** (1/0), (-1) ** (1/0) and 1 ** NaN are NaN, NaN ** 0
# is 1
subtest 'js_math_pow (Math.pow)' => sub {
  my $inf = 9**9**9;
  my $nan = $inf - $inf;
  my $s   = sub { $L->number_to_string( $_[0] ) };
  is( $s->( $L->js_math_pow( 10, 2 ) ),     '100',      '10 ** 2' );
  is( $s->( $L->js_math_pow( 10, -2 ) ),    '0.01',     '10 ** -2' );
  is( $s->( $L->js_math_pow( 1, $inf ) ),   'NaN',      '1 ** Infinity' );
  is( $s->( $L->js_math_pow( -1, -$inf ) ), 'NaN',      '-1 ** -Infinity' );
  is( $s->( $L->js_math_pow( 1, $nan ) ),   'NaN',      '1 ** NaN' );
  is( $s->( $L->js_math_pow( $nan, 0 ) ),   '1',        'NaN ** 0' );
  is( $s->( $L->js_math_pow( 2, $inf ) ),   'Infinity', '2 ** Infinity' );
};

# parseInt(string, radix) over a string and a Number radix (undef: undefined);
# every expected value is node's String(parseInt(s, radix)), -0 spelt '-0'
subtest 'js_parse_int (parseInt)' => sub {
  my $nan = 9**9**9 - 9**9**9;
  my $show = sub { my ($n) = @_; ( $n == 0 && sprintf( '%g', $n ) eq '-0' ) ? '-0' : $L->number_to_string($n) };
  for my $c (
    [ "42", undef, '42' ],
    [ "  -42px", undef, '-42' ],
    [ "+7", undef, '7' ],
    [ "\x{A0}\x{FEFF} 12", undef, '12' ],
    [ "\x{180E}12", undef, 'NaN' ],
    [ "0x1A", undef, '26' ],
    [ "0x1A", 16, '26' ],
    [ "0x1A", 10, '0' ],
    [ "1A", 16, '26' ],
    [ "0x", undef, 'NaN' ],
    [ "-0x10", undef, '-16' ],
    [ "101", 2, '5' ],
    [ "777", 8, '511' ],
    [ "zz", 36, '1295' ],
    [ "Zz", 36, '1295' ],
    [ "12", 37, 'NaN' ],
    [ "12", 1, 'NaN' ],
    [ "12", 0, '12' ],
    [ "12", -1, 'NaN' ],
    [ "12", 4294967306, '12' ],
    [ "12", 16.9, '18' ],
    [ "12", $nan, '12' ],
    [ "-0", undef, '-0' ],
    [ "-0x0", undef, '-0' ],
    [ "", undef, 'NaN' ],
    [ "abc", undef, 'NaN' ],
    [ "3.9", undef, '3' ],
    [ "1e21", undef, '1' ],
    [ "9007199254740993", undef, '9007199254740992' ],
    [ "123456789012345678901234567890", undef, '1.2345678901234568e+29' ],
    [ "1" . ( "0" x 52 ) . "10", 2, '18014398509481984' ],
    [ "1" . ( "0" x 52 ) . "11", 2, '18014398509481988' ],
    [ "1" . ( "0" x 52 ) . "101", 2, '36028797018963976' ],
    [ ( "f" x 18 ), 16, '4.722366482869645e+21' ],
    [ ( "z" x 16 ), 36, '7.958661109946401e+24' ],
    [ ( "7" x 21 ), 8, '9223372036854776000' ],
    [ ( "1" x 400 ), undef, 'Infinity' ],
    [ "\x{FF11}\x{FF12}", undef, 'NaN' ],
    [ "\x{663}", undef, 'NaN' ],
  ) {
    my ( $str, $radix, $want ) = @$c;
    is( $show->( $L->js_parse_int( $str, $radix ) ), $want,
      'parseInt(' . ( length($str) > 30 ? substr( $str, 0, 30 ) . '...' : $str ) =~ s/([^\x20-\x7e])/sprintf('\\u%04X', ord $1)/ger
        . ', ' . ( defined $radix ? $radix : 'undefined' ) . ')' );
  }
};

# parseFloat(string); every expected value is node's String(parseFloat(s))
subtest 'js_parse_float (parseFloat)' => sub {
  my $show = sub { my ($n) = @_; ( $n == 0 && sprintf( '%g', $n ) eq '-0' ) ? '-0' : $L->number_to_string($n) };
  for my $c (
    [ "3.5", '3.5' ],
    [ "  -3.5abc", '-3.5' ],
    [ ".5", '0.5' ],
    [ "5.", '5' ],
    [ "1e3", '1000' ],
    [ "1e", '1' ],
    [ "1e+", '1' ],
    [ "-.5e-3x", '-0.0005' ],
    [ "0x10", '0' ],
    [ "Infinity", 'Infinity' ],
    [ "-Infinityx", '-Infinity' ],
    [ "infinity", 'NaN' ],
    [ "+Infinity", 'Infinity' ],
    [ "Inf", 'NaN' ],
    [ "-0", '-0' ],
    [ "", 'NaN' ],
    [ "abc", 'NaN' ],
    [ "1_000", '1' ],
    [ "\x{2028}\x{3000} 2.5", '2.5' ],
    [ "\x{85} 1", 'NaN' ],
    [ "2.4703282292062328e-324", '5e-324' ],
    [ "1.7976931348623159e308", 'Infinity' ],
    [ "9007199254740993", '9007199254740992' ],
    [ "1" . ( "0" x 400 ), 'Infinity' ],
  ) {
    my ( $str, $want ) = @$c;
    is( $show->( $L->js_parse_float($str) ), $want,
      'parseFloat(' . ( length($str) > 30 ? substr( $str, 0, 30 ) . '...' : $str ) =~ s/([^\x20-\x7e])/sprintf('\\u%04X', ord $1)/ger . ')' );
  }
};

subtest '_js_to_int32 (ToInt32)' => sub {
  my $inf = 9**9**9;
  is( $L->_js_to_int32(undef),         0,           'undefined' );
  is( $L->_js_to_int32( $inf - $inf ), 0,           'NaN' );
  is( $L->_js_to_int32($inf),          0,           'Infinity' );
  is( $L->_js_to_int32(16.9),          16,          'truncates' );
  is( $L->_js_to_int32(-1),            -1,          'a negative stays' );
  is( $L->_js_to_int32(2147483648),    -2147483648, '2^31 wraps negative' );
  is( $L->_js_to_int32(4294967306),    10,          'modulo 2^32' );
};

# encodeURIComponent; every expected value is node's encodeURIComponent(s)
subtest 'js_encode_uri_component (encodeURIComponent)' => sub {
  for my $c (
    [ "abc", 'abc' ],
    [ "A-Z a-z 0-9 -_.!~*'()", 'A-Z%20a-z%200-9%20-_.!~*\'()' ],
    [ "a+b=c/d?e#f;g,h:i\@j\$k&l", 'a%2Bb%3Dc%2Fd%3Fe%23f%3Bg%2Ch%3Ai%40j%24k%26l' ],
    [ "\x{E9}\x{20AC}\x{1F600}", '%C3%A9%E2%82%AC%F0%9F%98%80' ],
    [ "\x{0}\x{7F}\x{80}\x{7FF}\x{800}\x{FFFD}", '%00%7F%C2%80%DF%BF%E0%A0%80%EF%BF%BD' ],
  ) {
    my ( $str, $want ) = @$c;
    is( $L->js_encode_uri_component($str), $want, 'encodeURIComponent: ' . $want );
  }
  is( $L->js_encode_uri_component("\x{D83D}\x{DE00}"), '%F0%9F%98%80', 'a pair spelt as two surrogates is one character' );
  for my $lone ( "\x{D83D}", "a\x{DE00}", "\x{DE00}\x{D83D}" ) {
    my $err = do { local $@; eval { $L->js_encode_uri_component($lone); 1 } ? undef : $@ };
    ok( $err && $err->isa('Text::Nunjucks::Lib::Error'), 'a lone surrogate throws' );
    is( $err && $err->name,    'URIError',      '... a URIError' );
    is( $err && $err->message, 'URI malformed', '... URI malformed (oracle: "\u{1F600}"|first|urlencode)' );
  }
};

done_testing;
