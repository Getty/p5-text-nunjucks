#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Scalar::Util qw( blessed );
use builtin qw( true false );

no warnings 'experimental::builtin';

# Perl-side API tests for the Environment/Context/Template/Loader surface ported
# in k16 that the render corpus does not exercise: the registration methods and
# their exact (upstream-text) errors, globals, extensions, and the on/emit event
# surface. Behaviour that the oracle grounds (rendering, tests, inheritance)
# lives in t/corpus/*.json, not here.

use Text::Nunjucks::Environment;
use Text::Nunjucks::Loader;
use Text::Nunjucks::Runtime;

sub msg { my ($e) = @_; blessed($e) && $e->can('message') ? $e->message : "$e" }

#### render API -- sync return and callback form

subtest 'render_string sync and callback forms' => sub {
  my $env = Text::Nunjucks::Environment->new( undef, {} );

  is( $env->render_string( 'Hi {{ x }}', { x => 'there' } ), 'Hi there', 'sync return' );

  my ( $err, $res );
  $env->render_string( '{{ 1 + 1 }}', {}, sub { ( $err, $res ) = @_ } );
  is( $err, undef, 'callback: no error' );
  is( $res, '2',   'callback: result' );
};

subtest 'render_string reports a template error through the callback' => sub {
  my $env = Text::Nunjucks::Environment->new( undef, {} );
  my ( $err, $res );
  $env->render_string( '{% foo %}', {}, sub { ( $err, $res ) = @_ } );
  ok( $err, 'callback received an error' );
  is( $err->name, 'Template render error', 'error name is the Nunjucks name' );
  like( $err->message, qr/unknown block tag: foo/, 'message carries the cause' );
  like( $err->message, qr/\Q(unknown path) [Line 1, Column 4]\E/, 'positioned message' );
};

#### filters / tests registration + not-found errors (upstream message text)

subtest 'add_filter / get_filter' => sub {
  my $env = Text::Nunjucks::Environment->new( undef, {} );
  is( $env->add_filter( 'shout', sub { uc $_[0] } ), $env, 'add_filter returns self' );
  is( $env->render_string( '{{ "hi" | shout }}', {} ), 'HI', 'custom filter runs' );

  my $err;
  eval { $env->get_filter('nope'); 1 } or $err = $@;
  is( msg($err), 'filter not found: nope', 'get_filter throws upstream text' );
};

subtest 'add_test / get_test' => sub {
  my $env = Text::Nunjucks::Environment->new( undef, {} );
  $env->add_test( 'big', sub { $_[0] > 100 ? true : false } );
  is( $env->render_string( '{{ 200 is big }}{{ 5 is big }}', {} ), 'truefalse', 'custom test runs' );

  # built-in tests are registered by init (Text::Nunjucks::Tests)
  is( $env->render_string( '{{ 5 is odd }}', {} ), 'true', 'built-in test present' );

  my $err;
  eval { $env->get_test('nope'); 1 } or $err = $@;
  is( msg($err), 'test not found: nope', 'get_test throws upstream text' );
};

#### globals

subtest 'add_global / get_global' => sub {
  my $env = Text::Nunjucks::Environment->new( undef, {} );
  is( $env->add_global( 'site', 'acme' ), $env, 'add_global returns self' );
  is( $env->get_global('site'), 'acme', 'get_global reads it back' );
  is( $env->render_string( '{{ site }}', {} ), 'acme', 'global visible in template' );
  is( $env->render_string( '{{ site }}', { site => 'local' } ), 'local', 'ctx shadows global' );

  my $err;
  eval { $env->get_global('missing'); 1 } or $err = $@;
  is( msg($err), 'global not found: missing', 'get_global throws upstream text' );
};

#### extensions

subtest 'extensions add / has / get / remove' => sub {
  my $env = Text::Nunjucks::Environment->new( undef, {} );
  my $ext = {};
  is( $env->has_extension('e'), 0, 'not present initially' );
  is( $env->add_extension( 'e', $ext ), $env, 'add_extension returns self' );
  is( $env->has_extension('e'), 1, 'present after add' );
  is( $env->get_extension('e'), $ext, 'get_extension returns it' );
  is( $ext->{__name}, 'e', '__name stamped on the extension' );
  is_deeply( $env->extensions_list, [$ext], 'extensions_list has it' );

  $env->remove_extension('e');
  is( $env->has_extension('e'), 0, 'gone after remove' );
  is_deeply( $env->extensions_list, [], 'extensions_list emptied' );
};

#### loader event surface (on/emit): loader emits -> Environment re-emits

subtest 'loader on/emit propagates to the Environment' => sub {
  my $loader = Text::Nunjucks::Loader->new;
  my $env    = Text::Nunjucks::Environment->new( [$loader], {} );

  my @updates;
  $env->on( 'update', sub { push @updates, [@_] } );
  my @loads;
  $env->on( 'load', sub { push @loads, [@_] } );

  # _init_loaders wired loader.on('update'|'load') -> env.emit(...); reset cache
  # first so we can observe the cache-busting the 'update' listener performs.
  $loader->cache->{'a.njk'} = 'cached';
  $loader->emit( 'update', 'a.njk', '/abs/a.njk' );
  is( scalar @updates, 1, 'env re-emitted update' );
  is( $updates[0][0], 'a.njk', 'update name forwarded' );
  is( $updates[0][1], '/abs/a.njk', 'update fullname forwarded' );
  is( $updates[0][2], $loader, 'update carries the loader' );
  ok( !defined $loader->cache->{'a.njk'}, 'update listener busted the cache entry' );

  $loader->emit( 'load', 'b.njk', 'body' );
  is( scalar @loads, 1, 'env re-emitted load' );
  is( $loads[0][1], 'body', 'load source forwarded' );
};

#### loader base: is_relative

subtest 'Loader is_relative' => sub {
  my $loader = Text::Nunjucks::Loader->new;
  is( $loader->is_relative('./x.njk'),  1, './ is relative' );
  is( $loader->is_relative('../x.njk'), 1, '../ is relative' );
  is( $loader->is_relative('x.njk'),    0, 'plain name is not relative' );
};

done_testing;
