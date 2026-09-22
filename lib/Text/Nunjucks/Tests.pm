package Text::Nunjucks::Tests;
# ABSTRACT: 1:1 port of Nunjucks src/tests.js -- the built-in `is` tests

use strict;
use warnings;
use builtin qw( true false );
use Text::Nunjucks::Runtime;
use Text::Nunjucks::Lib;

no warnings 'experimental::builtin';

# tests.js is a bag of `exports.<name> = fn` test functions. The port mirrors
# that: `exports` returns { name => coderef } (what Environment.init iterates via
# lib._entries(tests) and registers with add_test). Every test returns a JS
# boolean, because the compiler wraps a test call in op_seq(result, true) -- a
# 1/0 result would strict-compare unequal to `true`. So each returns true/false.
#
# JS operators (===, %, <, ...) go through Runtime (never Perl's native ones):
# ADR 0001 kinds, ADR 0006 None, ADR 0007 numbers. Value kinds come from Lib.
#
# NOTE (porting order): tests.js sits after environment.js in the pipeline, but
# environment.js `require`s it and the render corpus's `x is none` needs the
# `null` test, so it is ported here alongside k16. `iterable` (Symbol.iterator)
# and `mapping` (ES6 Set) have no direct Perl analogue and are mapped to the
# array/string and object-hash surfaces (ADR 0008/0011); flagged for the k17
# tests audit -- no corpus case exercises them yet.

sub _rt { 'Text::Nunjucks::Runtime' }
sub _lib { 'Text::Nunjucks::Lib' }

# callable(value): typeof value === 'function'
sub callable {
  my ($value) = @_;
  return __PACKAGE__->_lib->is_function($value) ? true : false;
}

# defined(value): value !== undefined  (JS null is defined, ADR 0006)
sub defined {
  my ($value) = @_;
  return defined($value) ? true : false;
}

# divisibleby(one, two): (one % two) === 0
sub divisibleby {
  my ( $one, $two ) = @_;
  return __PACKAGE__->_rt->op_seq( __PACKAGE__->_rt->op_mod( $one, $two ), 0 );
}

# escaped(value): value instanceof SafeString
sub escaped {
  my ($value) = @_;
  return __PACKAGE__->_rt->_is_safe_string($value) ? true : false;
}

# equalto(one, two): one === two
sub equalto {
  my ( $one, $two ) = @_;
  return __PACKAGE__->_rt->op_seq( $one, $two );
}

# even(value): value % 2 === 0
sub even {
  my ($value) = @_;
  return __PACKAGE__->_rt->op_seq( __PACKAGE__->_rt->op_mod( $value, 2 ), 0 );
}

# falsy(value): !value
sub falsy {
  my ($value) = @_;
  return __PACKAGE__->_rt->_falsy($value) ? true : false;
}

# ge(one, two): one >= two
sub ge {
  my ( $one, $two ) = @_;
  return __PACKAGE__->_rt->op_ge( $one, $two );
}

# greaterthan(one, two): one > two
sub greaterthan {
  my ( $one, $two ) = @_;
  return __PACKAGE__->_rt->op_gt( $one, $two );
}

# le(one, two): one <= two
sub le {
  my ( $one, $two ) = @_;
  return __PACKAGE__->_rt->op_le( $one, $two );
}

# lessthan(one, two): one < two
sub lessthan {
  my ( $one, $two ) = @_;
  return __PACKAGE__->_rt->op_lt( $one, $two );
}

# lower(value): value.toLowerCase() === value
sub lower {
  my ($value) = @_;
  return __PACKAGE__->_rt->op_seq( lc($value), $value );
}

# ne(one, two): one !== two
sub ne {
  my ( $one, $two ) = @_;
  return __PACKAGE__->_rt->op_sne( $one, $two );
}

# null(value): value === null  (JS null is the None sentinel, ADR 0006)
sub null {
  my ($value) = @_;
  return __PACKAGE__->_rt->op_seq( $value, __PACKAGE__->_rt->None );
}

# number(value): typeof value === 'number'
sub number {
  my ($value) = @_;
  return ( defined($value) && builtin::created_as_number($value) ) ? true : false;
}

# odd(value): value % 2 === 1
sub odd {
  my ($value) = @_;
  return __PACKAGE__->_rt->op_seq( __PACKAGE__->_rt->op_mod( $value, 2 ), 1 );
}

# string(value): typeof value === 'string'
sub string {
  my ($value) = @_;
  return __PACKAGE__->_lib->is_string($value) ? true : false;
}

# truthy(value): !!value
sub truthy {
  my ($value) = @_;
  return __PACKAGE__->_rt->_truthy($value) ? true : false;
}

# undefined(value): value === undefined
sub undefined {
  my ($value) = @_;
  return !defined($value) ? true : false;
}

# upper(value): value.toUpperCase() === value
sub upper {
  my ($value) = @_;
  return __PACKAGE__->_rt->op_seq( uc($value), $value );
}

# iterable(value): !!value[Symbol.iterator] -- string or Array (ADR 0008; a plain
# object is NOT iterable in JS). Symbol.iterator has no Perl analogue: k17 audit.
sub iterable {
  my ($value) = @_;
  return ( __PACKAGE__->_lib->is_array($value) || __PACKAGE__->_lib->is_string($value) )
    ? true : false;
}

# mapping(value): a non-null object hash that is not an Array and not a Set. Perl
# has no Set; an ordered dict (ADR 0011) counts as a mapping. k17 audit.
sub mapping {
  my ($value) = @_;
  return false if !defined($value) || __PACKAGE__->_rt->_is_none($value);
  return true if __PACKAGE__->_rt->_is_ordered_hash($value);
  return __PACKAGE__->_lib->is_object($value) ? true : false;
}

# exports -- { name => coderef }, including the aliases tests.js registers.
sub exports {
  return {
    callable    => \&callable,
    defined     => \&defined,
    divisibleby => \&divisibleby,
    escaped     => \&escaped,
    equalto     => \&equalto,
    eq          => \&equalto,
    sameas      => \&equalto,
    even        => \&even,
    falsy       => \&falsy,
    ge          => \&ge,
    greaterthan => \&greaterthan,
    gt          => \&greaterthan,
    le          => \&le,
    lessthan    => \&lessthan,
    lt          => \&lessthan,
    lower       => \&lower,
    ne          => \&ne,
    null        => \&null,
    number      => \&number,
    odd         => \&odd,
    string      => \&string,
    truthy      => \&truthy,
    undefined   => \&undefined,
    upper       => \&upper,
    iterable    => \&iterable,
    mapping     => \&mapping,
  };
}

1;
