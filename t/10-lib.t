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

done_testing;
