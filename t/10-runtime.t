#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use builtin qw( true false is_bool );

no warnings 'experimental::builtin';

# Perl-side unit tests for Text::Nunjucks::Runtime (port of src/runtime.js) plus
# the ADR mechanisms it hosts and the Number->String routine added to Lib.
# render() does not exist yet (Environment/Compiler unported), so these exercise
# the runtime helpers DIRECTLY. Every expected value is oracle-grounded: it was
# derived from an equivalent template run through maint/oracle.js (the template
# is cited in the comment), never recalled. The end-to-end render-mode corpus
# cases that pin the same behaviour come with k16 (Environment).

use_ok('Text::Nunjucks::Runtime');
use_ok('Text::Nunjucks::Lib');

my $R = 'Text::Nunjucks::Runtime';
my $L = 'Text::Nunjucks::Lib';

# render-ish stringify helper for booleans/None/values, so an assertion reads
# the way the template's {{ ... }} output does.
sub s_ { my $v = shift; $R->_js_to_string($v) }

#### Number->String -- Lib->number_to_string (ADR 0007), oracle-grounded

subtest 'number_to_string (ECMAScript Number::toString)' => sub {
  # {{ 1/3 }} -> 0.3333333333333333, {{ 0.1 + 0.2 }} -> 0.30000000000000004
  is( $L->number_to_string( 1 / 3 ),     '0.3333333333333333',  '{{ 1/3 }}' );
  is( $L->number_to_string( 0.1 + 0.2 ), '0.30000000000000004', '{{ 0.1 + 0.2 }}' );
  is( $L->number_to_string( 10 / 4 ),    '2.5',                 '{{ 10/4 }}' );
  is( $L->number_to_string(100),         '100',                 '{{ 100 }}' );
  is( $L->number_to_string(3),           '3',                   'integer 3' );
  is( $L->number_to_string( 2 / 3 ),     '0.6666666666666666',  '{{ 2/3 }}' );
  is( $L->number_to_string( 22 / 7 ),    '3.142857142857143',   '{{ 22/7 }}' );
  is( $L->number_to_string( -1 / 3 ),    '-0.3333333333333333', 'negative sign' );

  # exponent thresholds (measured via computed values -- 1e21 does not lex)
  is( $L->number_to_string( 10**20 ), '100000000000000000000', '{{ 10 ** 20 }}' );
  is( $L->number_to_string( 10**21 ), '1e+21',                 '{{ 10 ** 21 }}' );
  is( $L->number_to_string( 10**22 ), '1e+22',                 '{{ 10 ** 22 }}' );
  is( $L->number_to_string( 1 / 1000000 ),  '0.000001', '{{ 1/1000000 }} (no exp)' );
  is( $L->number_to_string( 1 / 100000 ),   '0.00001',  '{{ 1/100000 }}' );
  is( $L->number_to_string( 1 / 10000000 ), '1e-7',     '{{ 1/10000000 }} (exp)' );
  is( $L->number_to_string( 1 / ( 10**21 ) ), '1e-21',  'small exponent' );

  # shortest round-trip on values Perl would keep as exact integers
  is( $L->number_to_string( 5**30 ), '931322574615478500000', '{{ 5 ** 30 }}' );
  is( $L->number_to_string( 2**53 ), '9007199254740992',      '{{ 2 ** 53 }}' );
  is( $L->number_to_string( 2**60 ), '1152921504606847000',   '{{ 2 ** 60 }}' );
  # big literal past double precision: parsed as a double, formatted shortest
  is( $L->number_to_string(1234567890123456789), '1234567890123456800', 'big int literal' );
  is( $L->number_to_string(9007199254740993),    '9007199254740992',    '2^53+1 rounds' );

  # specials
  my $inf = 9**9**9;
  is( $L->number_to_string($inf),    'Infinity',  '{{ 1/0 }}' );
  is( $L->number_to_string( -$inf ), '-Infinity', '{{ -1/0 }}' );
  is( $L->number_to_string( $inf - $inf ), 'NaN', '{{ 0/0 }}' );
  is( $L->number_to_string(0),    '0', 'zero' );
  is( $L->number_to_string(-0.0), '0', 'negative zero renders 0' );
};

#### JS operators -- Runtime (ADR 0007). Perl's native +,*,== lack JS semantics.

subtest 'op_add: add-or-concat by kind' => sub {
  is( s_( $R->op_add( 1, 1 ) ),        '2',  '{{ 1 + 1 }}' );
  is( s_( $R->op_add( '1', 1 ) ),      '11', q<{{ '1' + 1 }}> );
  is( s_( $R->op_add( '5', 3 ) ),      '53', q<{{ '5' + 3 }}> );
  is( s_( $R->op_add( true, 1 ) ),     '2',  '{{ true + 1 }}' );
  is( s_( $R->op_add( false, 1 ) ),    '1',  '{{ false + 1 }}' );
  is( s_( $R->op_add( 'a', 'b' ) ),    'ab', q<{{ 'a' + 'b' }}> );
  is( s_( $R->op_add( [ 1, 2 ], 1 ) ), '1,21', '{{ arr + 1 }} (array ToPrimitive)' );
  is( s_( $R->op_add( {}, 1 ) ),  '[object Object]1', '{{ o + 1 }}' );
  is( s_( $R->op_add( '', 5 ) ),  '5',  q<{{ '' + 5 }}> );
  # null + 1 -> 1 (null->0, numeric); none + 'y' -> "nully" (ToString(null))
  is( s_( $R->op_add( $R->None, 1 ) ),    '1',     '{{ n + 1 }} n=null (numeric)' );
  is( s_( $R->op_add( $R->None, 'y' ) ),  'nully', q<{{ none + 'y' }} (concat)> );
  is( s_( $R->op_add( undef, 'y' ) ),     'undefinedy', q<{{ u + 'y' }}> );
  is( s_( $R->op_add( undef, 1 ) ),       'NaN',   '{{ u + 1 }} (undefined->NaN)' );
};

subtest 'op_concat (~), sub/mul/div/mod/pow/floordiv' => sub {
  is( $R->op_concat( 1, 2 ),          '12',      '{{ 1 ~ 2 }}' );
  is( $R->op_concat( $R->op_concat( 'a', 3 ), true ), 'a3true', q<{{ 'a' ~ 3 ~ true }}> );
  is( $R->op_concat( $R->None, 'x' ), 'nullx',   q<{{ none ~ 'x' }}> );
  is( $R->op_concat( undef, 'x' ),    'undefinedx', q<{{ u ~ 'x' }}> );

  is( s_( $R->op_sub( '5', 1 ) ),   '4',   q<{{ '5' - 1 }}> );
  is( s_( $R->op_mul( '3', '2' ) ), '6',   q<{{ '3' * '2' }}> );
  is( s_( $R->op_mul( 'a', 2 ) ),   'NaN', q<{{ 'a' * 2 }}> );
  is( s_( $R->op_mul( 123456789, 987654321 ) ), '121932631112635260',
    'integer product forced into JS double arithmetic' );

  is( s_( $R->op_div( 10, 4 ) ), '2.5',      '{{ 10/4 }}' );
  is( s_( $R->op_div( 1, 0 ) ),  'Infinity', '{{ 1/0 }}' );
  is( s_( $R->op_div( -1, 0 ) ), '-Infinity','{{ -1/0 }}' );
  is( s_( $R->op_div( 0, 0 ) ),  'NaN',      '{{ 0/0 }}' );

  # F3: op_mul preserves IEEE -0 so a later division reads the sign of the zero
  is( s_( $R->op_mul( 0,  -1 ) ), '0', '{{ 0 * -1 }} renders 0 (but keeps -0 sign)' );
  is( s_( $R->op_div( 1,  $R->op_mul( 0,  -1 ) ) ), '-Infinity', '{{ 1/(0*-1) }}' );
  is( s_( $R->op_div( -1, $R->op_mul( 0,  -1 ) ) ), 'Infinity',  '{{ -1/(0*-1) }}' );
  is( s_( $R->op_div( 1,  $R->op_mul( 0,   1 ) ) ), 'Infinity',  '{{ 1/(0*1) }}' );
  is( s_( $R->op_div( 1,  $R->op_mul( -5,  0 ) ) ), '-Infinity', '{{ 1/(-5*0) }}' );

  is( s_( $R->op_mod( 7, 3 ) ),   '1',   '{{ 7 % 3 }}' );
  is( s_( $R->op_mod( -7, 3 ) ),  '-1',  '{{ -7 % 3 }} (sign of dividend)' );
  is( s_( $R->op_mod( 5.5, 2 ) ), '1.5', '{{ 5.5 % 2 }} (float mod)' );

  is( s_( $R->op_pow( 2, 0.5 ) ), '1.4142135623730951', '{{ 2 ** 0.5 }}' );
  is( s_( $R->op_pow( 2, 10 ) ),  '1024',               '{{ 2 ** 10 }}' );

  is( s_( $R->op_floordiv( 7, 2 ) ),  '3',  '{{ 7 // 2 }}' );
  is( s_( $R->op_floordiv( -7, 2 ) ), '-4', '{{ -7 // 2 }} (Math.floor, not trunc)' );

  is( s_( $R->op_neg(5) ),  '-5', '{{ -a }} a=5' );
  is( s_( $R->op_neg(0) ),  '0',  '{{ -0 }} -> 0' );
  is( s_( $R->op_pos('3') ),'3',  q<{{ +'3' }}> );
};

subtest 'comparisons: loose (==), strict (===), relational' => sub {
  is( s_( $R->op_eq( 1, '1' ) ),  'true',  q<{{ 1 == '1' }}> );
  is( s_( $R->op_seq( 1, '1' ) ), 'false', q<{{ 1 === '1' }}> );
  is( s_( $R->op_ne( 1, '1' ) ),  'false', q<{{ 1 != '1' }}> );
  is( s_( $R->op_sne( 1, '1' ) ), 'true',  q<{{ 1 !== '1' }}> );
  is( s_( $R->op_seq( 3, 3 ) ),   'true',  '{{ 3 === 3 }}' );

  is( s_( $R->op_eq( true, 1 ) ),  'true', '{{ true == 1 }}' );
  is( s_( $R->op_eq( false, 0 ) ), 'true', '{{ false == 0 }}' );
  is( s_( $R->op_eq( '', false ) ),'true', q<{{ '' == false }}> );

  # null / undefined loose-equality edges
  is( s_( $R->op_eq( $R->None, undef ) ),  'true',  '{{ n == u }} null==undefined' );
  is( s_( $R->op_eq( $R->None, $R->None ) ),'true', '{{ n == n }} null==null' );
  is( s_( $R->op_eq( $R->None, 0 ) ),      'false', '{{ n == 0 }} null==0' );

  is( s_( $R->op_lt( '10', '9' ) ), 'true',  "{{ '10' < '9' }} (string compare)" );
  is( s_( $R->op_lt( 10, 9 ) ),     'false', '{{ 10 < 9 }} (numeric)' );
  is( s_( $R->op_lt( '10', 9 ) ),   'false', "{{ '10' < 9 }} (mixed -> numeric)" );
  is( s_( $R->op_lt( 'a', 'b' ) ),  'true',  "{{ 'a' < 'b' }}" );
  is( s_( $R->op_lt( 'a', 1 ) ),    'false', "{{ 'a' < 1 }} (NaN -> false)" );
  is( s_( $R->op_lt( $R->None, 1 ) ),'true', '{{ n < 1 }} n=null (null->0)' );
  is( s_( $R->op_le( 2, 2 ) ),      'true',  '{{ 2 <= 2 }}' );
  is( s_( $R->op_ge( 3, 4 ) ),      'false', '{{ 3 >= 4 }}' );

  ok( is_bool( $R->op_eq( 1, 1 ) ), 'op_eq returns a boolean kind' );
};

subtest 'logical and/or/not and truthiness' => sub {
  # and/or return the operand, not a boolean
  is( $R->op_and( '0', 1 ), 1,   "{{ '0' and 1 }} -> 1 ('0' is truthy in JS)" );
  is( $R->op_or( 0, 'd' ),  'd', "{{ 0 or 'd' }} -> d" );
  is( s_( $R->op_not('0') ),  'false', q<{{ not '0' }}> );
  is( s_( $R->op_not(0) ),    'true',  '{{ not 0 }}' );
  is( s_( $R->op_not( [] ) ), 'false', '{{ not [] }} (empty array truthy)' );

  ok( !$R->_falsy('0'),      q<'0' is truthy (Perl disagrees)> );
  ok( !$R->_falsy( [] ),     'empty array truthy' );
  ok( !$R->_falsy( {} ),     'empty hash truthy' );
  ok( $R->_falsy(0),         '0 is falsy' );
  ok( $R->_falsy(''),        'empty string falsy' );
  ok( $R->_falsy(false),     'false is falsy' );
  ok( $R->_falsy(undef),     'undef (undefined) falsy' );
  ok( $R->_falsy( $R->None ),'None (null) falsy -- a ref, so Lib alone would miss it' );
  ok( !$R->_falsy( $R->SafeString->new('') ), 'empty SafeString truthy (an object)' );
};

#### undefined vs null distinction -- ADR 0006 (the substrate is/none/defined ride on)

subtest 'None sentinel vs undef (ADR 0006)' => sub {
  ok( $R->_is_none( $R->None ), 'None is the null sentinel' );
  ok( !$R->_is_none(undef),     'undef is not None' );
  ok( !$R->_is_none(0),         '0 is not None' );
  is( $R->None, $R->None, 'None is a single process-wide singleton' );

  # is defined / is none / is undefined build on: defined(None)=true, defined(undef)=false
  ok( defined( $R->None ), 'None is defined -> {{ n is defined }} true' );
  ok( !defined(undef),     'undef is not defined -> {{ u is defined }} false' );

  # rendering: both empty  ( [{{ n }}] / [{{ u }}] -> [] )
  is( $R->suppress_value( $R->None, 1 ), '', '{{ n }} renders empty' );
  is( $R->suppress_value( undef, 1 ),    '', '{{ u }} renders empty' );

  # member lookup on either -> undefined, no error ( {{ n.foo }} / {{ u.foo }} )
  is( $R->member_lookup( $R->None, 'foo' ), undef, '{{ n.foo }} -> undefined' );
  is( $R->member_lookup( undef, 'foo' ),    undef, '{{ u.foo }} -> undefined' );

  # throwOnUndefined fires for BOTH ( {{ a.b.c }} with throwOnUndefined )
  for my $pair ( [ undef, 'undefined' ], [ $R->None, 'null' ] ) {
    my $err;
    eval { $R->ensure_defined( $pair->[0], 0, 0 ); 1 } or $err = $@;
    ok( ref($err) && $err->isa('Text::Nunjucks::Lib::TemplateError'),
      'ensure_defined dies for ' . $pair->[1] );
    is( $err->message, 'attempted to output null or undefined value',
      'throwOnUndefined message (' . $pair->[1] . ')' );
  }
};

#### memberLookup emulated surface -- ADR 0008, oracle-grounded

subtest 'member_lookup: strings' => sub {
  is( $R->member_lookup( 'abc',  'length' ), 3, '{{ s.length }}' );
  is( $R->member_lookup( 'abcd', 'length' ), 4, q<{{ s['length'] }}> );
  is( $R->member_lookup( 'abc', 1 ),   'b', '{{ s[1] }}' );
  is( $R->member_lookup( 'abc', 9 ),   undef, '{{ s[9] }} out of range -> undefined' );
  is( _call( 'abc', 'toUpperCase' ),   'ABC', '{{ s.toUpperCase() }}' );
  is( _call( 'ABC', 'toLowerCase' ),   'abc', '{{ s.toLowerCase() }}' );
  is( _call( '  hi  ', 'trim' ),       'hi',  '{{ s.trim() }}' );
  is( _call( 'abcde', 'slice', 1, 3 ), 'bc',  '{{ s.slice(1,3) }}' );
  is( _call( 'abcde', 'slice', -2 ),   'de',  '{{ s.slice(-2) }}' );
  is( _call( 'abcde', 'substring', 1, 3 ), 'bc', '{{ s.substring(1,3) }}' );
  is( _call( 'banana', 'replace', 'a', 'X' ), 'bXnana', q<{{ s.replace('a','X') }} (first only)> );
  is( _call( 'abc', 'charAt', 1 ),     'b',  '{{ s.charAt(1) }}' );
  is( _call( 'abc', 'indexOf', 'b' ),  1,    q<{{ s.indexOf('b') }}> );
  is( _call( 'abc', 'concat', 'def' ), 'abcdef', q<{{ s.concat('def') }}> );
  is( join( '|', @{ _call( 'a,b,c', 'split', ',' ) } ), 'a|b|c', q<{{ s.split(',') }}> );
  is( join( '|', @{ _call( 'abc', 'split', '' ) } ),    'a|b|c', q<{{ s.split('') }}> );
};

subtest 'member_lookup: arrays (incl. in-place mutators)' => sub {
  is( $R->member_lookup( [ 1, 2, 3 ], 'length' ), 3, '{{ arr.length }}' );
  is( $R->member_lookup( [ 7, 8, 9 ], 0 ),        7, '{{ arr[0] }}' );
  is( $R->member_lookup( [ 7, 8, 9 ], '1' ),      8, q<{{ arr['1'] }}> );
  is( $R->member_lookup( [ 1, 2, 3 ], 9 ),    undef, '{{ arr[9] }} -> undefined' );

  is( _call( [ 1, 2, 3 ], 'join', '-' ), '1-2-3', q<{{ arr.join('-') }}> );
  is( _call( [ 1, 2, 3 ], 'join' ),      '1,2,3', '{{ arr.join() }} default sep' );
  is( _call( [ 1, undef, 3 ], 'join', '-' ), '1--3', 'join maps null/undef -> ""' );
  is( _call( [ 3, 1, 2 ], 'indexOf', 1 ),   1,  '{{ arr.indexOf(1) }}' );
  is( _call( [ 3, 1, 2 ], 'indexOf', '3' ), -1, q<{{ arr.indexOf('3') }} strict !== 3> );
  is( s_( _call( [ 1, 2, 3 ], 'slice', 1, 3 ) ),   '2,3',   '{{ arr.slice(1,3) }}' );
  is( s_( _call( [ 1, 2, 3 ], 'concat', [ 4, 5 ] ) ), '1,2,3,4,5', '{{ arr.concat([4,5]) }}' );

  # mutators change the underlying arrayref in place and return JS values
  my $a = [ 3, 1, 2 ];
  is( _call( $a, 'push', 4 ), 4, '{{ arr.push(4) }} returns new length' );
  is( s_($a), '3,1,2,4', '... and mutates the array in place' );

  my $b = [ 3, 1, 2 ];
  is( _call( $b, 'pop' ), 2, 'pop returns last' );
  is( s_($b), '3,1', '... mutated' );

  my $c = [ 3, 1, 2 ];
  is( _call( $c, 'shift' ), 3, 'shift returns first' );
  is( s_($c), '1,2', '... mutated' );

  my $d = [ 3, 1, 2 ];
  is( _call( $d, 'unshift', 9 ), 4, 'unshift returns new length' );
  is( s_($d), '9,3,1,2', '... mutated' );

  my $e = [ 3, 1, 2 ];
  _call( $e, 'reverse' );
  is( s_($e), '2,1,3', 'reverse mutates in place' );

  my $f = [ 3, 1, 2, 10 ];
  _call( $f, 'sort' );
  is( s_($f), '1,10,2,3', 'sort() is a default STRING sort, in place' );
};

subtest 'member_lookup: numbers, hashes, blessed objects' => sub {
  is( _call( 3.14159, 'toFixed', 2 ), '3.14', '{{ n.toFixed(2) }}' );
  is( _call( 3,       'toFixed', 2 ), '3.00', '{{ n.toFixed(2) }} n=3' );
  is( _call( 3.7,     'toFixed' ),    '4',    '{{ n.toFixed() }} default 0 digits' );

  is( $R->member_lookup( { a => 42 }, 'a' ),  42,    '{{ o.a }}' );
  is( $R->member_lookup( { a => 42 }, 'z' ),  undef, '{{ o.z }} missing -> undefined' );
  is( $R->member_lookup( $R->member_lookup( { a => { b => 7 } }, 'a' ), 'b' ),
    7, '{{ a.b }} nested' );

  # blessed object: a member call binds the owner as $self (ADR 0009)
  my $obj = TN_Test_Obj->new('world');
  my $m   = $R->member_lookup( $obj, 'greet' );
  ok( ref($m) eq 'CODE', 'method member -> a bound closure' );
  is( $R->call_wrap( $m, 'obj.greet', undef, [] ), 'hi world',
    'member call runs $obj->greet, owner bound' );
  is( $R->member_lookup( $obj, 'nonesuch' ), undef, 'missing method -> undefined' );
};

subtest 'member_lookup: SafeString is a String OBJECT, not a primitive (F1)' => sub {
  # {% set s = 'abc'|safe %} ... a SafeString has length + methods but NO exotic
  # index access ({{ s[0] }} and {{ s['0'] }} render '', unlike a plain string).
  my $ss = $R->SafeString->new('abcde');
  is( $R->member_lookup( $ss, 0 ),   undef, '{{ s[0] }} on SafeString -> undefined' );
  is( $R->member_lookup( $ss, '0' ), undef, "{{ s['0'] }} on SafeString -> undefined" );
  is( $R->member_lookup( $ss, 'length' ), 5, '{{ s.length }} on SafeString still works' );
  is( _call( $ss, 'toUpperCase' ), 'ABCDE', 'SafeString.toUpperCase() works' );
  is( _call( $ss, 'charAt', 1 ),   'b',     'SafeString.charAt(1) works' );
  is( _call( $ss, 'slice', 1, 3 ), 'bc',    'SafeString.slice(1,3) works' );
  # a plain string still HAS index access
  is( $R->member_lookup( 'abc', 0 ), 'a', '{{ s[0] }} on a plain string -> char' );
};

#### callWrap / kwargs / macros -- ADR 0009

subtest 'callWrap error text and dispatch' => sub {
  # {{ s.nope() }} : the compiler passes a name string; callWrap interpolates it
  my $err;
  eval { $R->call_wrap( undef, 's["nope"]', undef, [] ); 1 } or $err = $@;
  ok( ref($err) && $err->isa('Text::Nunjucks::Lib::Error'), 'undefined callee dies with an Error' );
  is( $err->message, 'Unable to call `s["nope"]`, which is undefined or falsey',
    'exact upstream text for undefined/falsey callee' );

  # {{ s.length() }} : length is a number, not callable
  undef $err;
  eval { $R->call_wrap( 3, 's["length"]', undef, [] ); 1 } or $err = $@;
  is( $err->message, 'Unable to call `s["length"]`, which is not a function',
    'exact upstream text for non-function callee' );

  # bare context coderef: called with args, no `this` (ADR 0009 divergence)
  my @seen;
  my $code = sub { @seen = @_; return 'r=' . join( ',', @_ ) };
  is( $R->call_wrap( $code, 'fn', 'CTX', [ 1, 2 ] ), 'r=1,2', 'bare coderef called with args' );
  is_deeply( \@seen, [ 1, 2 ], 'no Context prepended as invocant' );
};

subtest 'makeKeywordArgs / isKeywordArgs / getKeywordArgs / numArgs' => sub {
  my $kw = $R->make_keyword_args( { a => 1, b => 2 } );
  ok( $R->is_keyword_args($kw), 'blessed KwArgs is recognised' );
  ok( !$R->is_keyword_args( { a => 1 } ), 'a plain hashref is not KwArgs' );
  ok( !$R->is_keyword_args(undef),        'undef is not KwArgs' );
  is( $kw->{a}, 1, 'KwArgs hash keys are the keyword values (no __keywords key)' );

  is_deeply( $R->get_keyword_args( [ 1, 2, $kw ] ), $kw, 'trailing KwArgs returned' );
  is_deeply( $R->get_keyword_args( [ 1, 2 ] ),      {},  'no trailing KwArgs -> {}' );
  is_deeply( $R->get_keyword_args( [] ),            {},  'empty args -> {}' );

  is( $R->num_args( [] ),            0, 'numArgs [] = 0' );
  is( $R->num_args( [ 1, 2 ] ),      2, 'numArgs of plain args' );
  is( $R->num_args( [ 1, 2, $kw ] ), 2, 'numArgs excludes trailing KwArgs' );
};

subtest 'makeMacro: positional <-> keyword remapping' => sub {
  # equal arity: args passed straight through
  {
    my @got;
    my $macro = $R->make_macro( [qw( a b )], [], sub { @got = @_; '' } );
    $macro->( 1, 2 );
    is_deeply( \@got, [ 1, 2 ], 'argCount == argNames: (a, b)' );
  }
  # extra positional -> folded into kwargs by kwargNames position
  {
    my @got;
    my $macro = $R->make_macro( ['a'], ['b'], sub { @got = @_; '' } );
    $macro->( 1, 2 );
    is( $got[0], 1, 'first positional kept' );
    # getKeywordArgs returned a plain {} here (no trailing __keywords), matching
    # upstream: the overflow bag is an ordinary hashref, not a marked KwArgs.
    is( ref( $got[1] ), 'HASH', 'overflow collected into a trailing kwargs hashref' );
    is( $got[1]{b}, 2, 'extra positional placed under kwargName b' );
  }
  # too few positional -> filled from kwargs passed by name
  {
    my @got;
    my $macro = $R->make_macro( [qw( a b )], [], sub { @got = @_; '' } );
    $macro->( 1, $R->make_keyword_args( { b => 2 } ) );
    is( $got[0], 1, 'positional a' );
    is( $got[1], 2, 'b pulled from kwargs by name' );
    is_deeply( $got[2], {}, 'consumed kwarg removed, empty kwargs trail' );
  }
};

#### ported runtime.js structural pieces

subtest 'Frame: set / get / lookup / resolve / push / pop' => sub {
  my $f = $R->Frame->new;
  is_deeply( $f->variables, {}, 'fresh variables bag' );
  is( $f->parent,    undef, 'no parent' );
  is( $f->top_level, 0,     'topLevel starts false' );

  $f->set( 'a', 1 );
  is( $f->get('a'),    1, 'get returns a set value' );
  is( $f->lookup('a'), 1, 'lookup returns a set value' );
  is( $f->get('missing'),    $R->None, 'get missing -> null (None)' );
  is( $f->lookup('missing'), undef,    'lookup missing -> undefined (undef)' );

  $f->set( 'x.y.z', 5 );
  is( $f->variables->{x}{y}{z}, 5, 'dotted set builds nested structure' );

  my $child = $f->push;
  is( $child->parent, $f, 'push creates a child with parent' );
  is( $child->lookup('a'), 1, 'child reads through to parent (lookup)' );
  is( $child->pop, $f, 'pop returns the parent' );

  is( $f->resolve('a'), $f, 'resolve finds the owning frame' );
  is( $child->resolve('a'), $f, 'resolve walks up to the owner' );

  # resolveUp writes to the owning ancestor
  $child->set( 'a', 99, 1 );
  is( $f->get('a'), 99, 'set(resolveUp) writes to the ancestor that owns it' );

  # isolate_writes blocks the upward write, forcing a local one
  my $iso = $f->push(1);
  $iso->set( 'a', 7, 1 );
  is( $iso->variables->{a}, 7,  'isolateWrites keeps the write local' );
  is( $f->get('a'),         99, '... parent value untouched' );
};

subtest 'suppress_value' => sub {
  is( $R->suppress_value( '<b>', 1 ), '&lt;b&gt;', 'autoescape on escapes' );
  is( $R->suppress_value( '<b>', 0 ), '<b>',       'autoescape off leaves raw' );
  is( $R->suppress_value( $R->None, 1 ), '', 'null -> empty' );
  is( $R->suppress_value( undef, 1 ),    '', 'undefined -> empty' );
  my $safe = $R->SafeString->new('<b>');
  is( $R->suppress_value( $safe, 1 ), $safe, 'SafeString not escaped even with autoescape' );
  is( "$safe", '<b>', 'SafeString stringifies to its value' );
};

subtest 'SafeString / markSafe / copySafeness' => sub {
  my $ss = $R->SafeString->new('hi');
  ok( $R->_is_safe_string($ss), 'SafeString recognised' );
  is( $ss->val,    'hi', 'val' );
  is( $ss->length, 2,    'length' );
  is( "$ss",       'hi', 'stringification overload' );
  # non-string passes through unchanged (JS: new SafeString(5) === 5)
  is( $R->SafeString->new(5), 5, 'SafeString(non-string) returns the value' );

  my $m = $R->mark_safe('<x>');
  ok( $R->_is_safe_string($m), 'mark_safe on a string -> SafeString' );
  is( $R->mark_safe(5), 5, 'mark_safe on a non-string/non-fn -> value' );
  my $wrapped = $R->mark_safe( sub { 'raw<>' } );
  ok( $R->_is_safe_string( $wrapped->() ), 'mark_safe on a fn wraps a string return' );

  # copySafeness: SafeString dest -> SafeString(target); else target.toString()
  ok( $R->_is_safe_string( $R->copy_safeness( $ss, 'new' ) ), 'safe dest -> safe result' );
  my $plain = $R->copy_safeness( 'plain', 'new' );
  ok( !$R->_is_safe_string($plain), 'plain dest -> plain result' );
  is( $plain, 'new', 'plain result is the target string' );
};

subtest 'ensure_defined / handle_error / context_or_frame_lookup' => sub {
  is( $R->ensure_defined( 0, 0, 0 ),  0,  'ensure_defined passes 0 through' );
  is( $R->ensure_defined( '', 0, 0 ), '', 'ensure_defined passes empty string' );

  # handle_error wraps a bare error; leaves an already-positioned one alone
  my $wrapped = $R->handle_error( 'boom', 3, 4 );
  ok( $wrapped->isa('Text::Nunjucks::Lib::TemplateError'), 'bare error -> TemplateError' );
  my $te = Text::Nunjucks::Lib::TemplateError->new( 'x', 1, 2 );
  is( $R->handle_error( $te, 9, 9 ), $te, 'already-positioned error returned as-is' );

  # contextOrFrameLookup: frame wins if defined, else context
  my $frame = $R->Frame->new;
  $frame->set( 'x', 'from_frame' );
  my $ctx = TN_Test_Ctx->new( { x => 'from_ctx', y => 'from_ctx' } );
  is( $R->context_or_frame_lookup( $ctx, $frame, 'x' ), 'from_frame', 'frame value preferred' );
  is( $R->context_or_frame_lookup( $ctx, $frame, 'y' ), 'from_ctx',   'falls back to context' );
};

subtest 'asyncEach / asyncAll / fromIterator (CPS, ADR 0003 -- sync here)' => sub {
  # asyncAll over an array (dimen 1) joins outputs in order
  my $res;
  $R->async_all(
    [ 1, 2, 3 ], 1,
    sub { my ( $item, $i, $len, $done ) = @_; $done->( $i, "<$item>" ) },
    sub { ( undef, $res ) = @_ },
  );
  is( $res, '<1><2><3>', 'asyncAll array collects outputs' );

  # asyncAll over an empty array -> ''
  undef $res;
  $R->async_all( [], 1, sub { }, sub { ( undef, $res ) = @_ } );
  is( $res, '', 'asyncAll empty array -> empty' );

  # asyncAll over an object
  undef $res;
  $R->async_all(
    { a => 10 }, 1,
    sub { my ( $k, $v, $i, $len, $done ) = @_; $done->( $i, "$k=$v" ) },
    sub { ( undef, $res ) = @_ },
  );
  is( $res, 'a=10', 'asyncAll object collects key=val' );

  # asyncEach array (dimen 1)
  my @seen;
  $R->async_each(
    [ 'p', 'q' ], 1,
    sub { my ( $item, $i, $len, $next ) = @_; push @seen, "$i:$item:$len"; $next->() },
    sub { push @seen, 'done' },
  );
  is_deeply( \@seen, [ '0:p:2', '1:q:2', 'done' ], 'asyncEach array iterates then cb' );

  # asyncEach object
  @seen = ();
  $R->async_each(
    { k => 'v' }, 1,
    sub { my ( $key, $val, $i, $len, $next ) = @_; push @seen, "$key=$val"; $next->() },
    sub { push @seen, 'done' },
  );
  is_deeply( \@seen, [ 'k=v', 'done' ], 'asyncEach object iterates then cb' );

  # fromIterator: identity for the value kinds Perl models
  my $arr = [ 1, 2 ];
  is( $R->from_iterator($arr), $arr,     'array passes through' );
  is( $R->from_iterator('s'),  's',      'scalar passes through' );
  is( $R->from_iterator(undef), undef,   'undef passes through' );
  is( $R->from_iterator( $R->None ), $R->None, 'None passes through' );
};

subtest 'async loops over null / falsy iterables (F2)' => sub {
  # {% asyncEach/asyncAll x in n %}...{% end %} with n = null/undefined/0/'' ->
  # empty output, never a crash on Lib->keys deref (JS: keys(arr || {})).
  for my $case ( [ $R->None, 'null' ], [ undef, 'undefined' ], [ 0, 'zero' ], [ '', 'empty string' ] ) {
    my ( $val, $label ) = @$case;

    my $out;
    my $ok = eval {
      $R->async_all( $val, 1, sub { }, sub { ( undef, $out ) = @_ } );
      1;
    };
    ok( $ok, "async_all over $label does not crash" );
    is( $out, '', "async_all over $label -> empty" );

    my @seen;
    $ok = eval {
      $R->async_each( $val, 1, sub { push @seen, 'iter' }, sub { push @seen, 'done' } );
      1;
    };
    ok( $ok, "async_each over $label does not crash" );
    is_deeply( \@seen, ['done'], "async_each over $label -> empty loop, cb fires" );
  }

  # a real object still iterates
  my $out;
  $R->async_all( { a => 1 }, 1,
    sub { my ( $k, $v, $i, $l, $d ) = @_; $d->( $i, "$k=$v" ) },
    sub { ( undef, $out ) = @_ } );
  is( $out, 'a=1', 'async_all over a non-empty object still iterates' );
};

subtest 'async loops over Hash::Ordered values (k41)' => sub {
  # ADR 0011: template dict literals and engine-built objects are Hash::Ordered.
  # Lib::async_for reads via the Hash::Ordered branch; Runtime::async_all reads
  # via member_lookup (which already handles Hash::Ordered). A Hash::Ordered
  # caller arg must not die "Not a HASH reference" on either loop.
  my $items = Hash::Ordered->new( foo => 1, bar => 2, baz => 3 );

  # async_all collects outputs in insertion order
  my $out;
  $R->async_all(
    $items, 1,
    sub { my ( $k, $v, $i, $l, $d ) = @_; $d->( $i, "$k=$v" ) },
    sub { ( undef, $out ) = @_ },
  );
  is( $out, 'foo=1bar=2baz=3', 'async_all over Hash::Ordered collects in insertion order' );

  # async_each iterates the same way
  my @seen;
  $R->async_each(
    $items, 1,
    sub {
      my ( $k, $v, $i, $l, $next ) = @_;
      push @seen, "$i:$k=$v";
      $next->();
    },
    sub { push @seen, 'done' },
  );
  is_deeply(
    \@seen,
    [ '0:foo=1', '1:bar=2', '2:baz=3', 'done' ],
    'async_each over Hash::Ordered iterates in insertion order',
  );
};

subtest 'container ToString (_js_to_string) -- mechanism in Runtime' => sub {
  is( $R->_js_to_string( [ 3, 1, 2 ] ),   '3,1,2',           '{{ [3,1,2] }}' );
  is( $R->_js_to_string( {} ),            '[object Object]', '{{ {} }}' );
  is( $R->_js_to_string( [ $R->None, 1 ] ), ',1',            '{{ [none, 1] }}' );
  is( $R->_js_to_string( [ true, false ] ), 'true,false',    '{{ [true, false] }}' );
  is( $R->_js_to_string( [ 1, [ 2, 3 ] ] ), '1,2,3',         '{{ [1, [2,3]] }}' );
  is( $R->_js_to_string(true),  'true',  'ToString(true)' );
  is( $R->_js_to_string(false), 'false', 'ToString(false)' );
  is( $R->_js_to_string( 1 / 3 ), '0.3333333333333333', 'ToString routes numbers through Lib' );
};

subtest 're-exported lib helpers (isArray / keys / inOperator)' => sub {
  ok( $R->is_array( [ 1, 2 ] ), 'is_array delegates to Lib' );
  ok( !$R->is_array( {} ),      'is_array false on hash' );
  is_deeply( [ sort @{ $R->keys( { a => 1, b => 2 } ) } ], [qw( a b )], 'keys delegates to Lib' );
  ok( $R->in_operator( 'b', 'abc' ),  'in_operator: substring' );
  ok( $R->in_operator( 1, [ 1, 2 ] ), 'in_operator: array membership' );
};

done_testing;

# helper: look a member up and call it via call_wrap (the compiler's path)
sub _call {
  my ( $obj, $name, @args ) = @_;
  my $fn = $R->member_lookup( $obj, $name );
  return $R->call_wrap( $fn, $name, undef, \@args );
}

BEGIN {
  package TN_Test_Obj;
  sub new { my ( $c, $name ) = @_; bless { name => $name }, $c }
  sub greet { my ($self) = @_; 'hi ' . $self->{name} }

  package TN_Test_Ctx;
  sub new { my ( $c, $h ) = @_; bless { h => $h }, $c }
  sub lookup { my ( $self, $name ) = @_; $self->{h}{$name} }
}
