package Test::Nunjucks::Util;
# ABSTRACT: shared render() harness for ported upstream suites (t/upstream/*.t)
#
# Perl analogue of upstream/nunjucks/tests/util.js -- but util.js's render()
# builds a real Environment + FileSystemLoader and calls t.render(ctx, cb).
# Environment/Template (k16) are not ported yet, so this instead drives the
# part of the pipeline that IS ported -- Compiler (k15) + Runtime (k14) --
# through a minimal stub Environment/Context, the same shim t/10-compiler.t
# already uses and for the same reason (see its own header comment). Once
# k16 lands, replace the stub below with the real Environment/Context; the
# render() signature here should not need to change for that.
#
# util.js also exports `equal`, `jinjaEqual`, `finish` and `normEOL`. None of
# those are ported here yet -- no suite ported so far needs them. Port each
# alongside the first t/upstream/*.t that calls it, oracle-grounded like
# everything else, rather than writing them speculatively/unexercised now.
#
# `finish(done)` specifically has no Perl counterpart to add later either: it
# exists in util.js only to coordinate mocha's async done() with nunjucks'
# CPS callbacks that may or may not fire synchronously. Perl callbacks in
# this port run synchronously unless user code defers them (ADR 0003), and
# Test::More has no `done` ceremony -- render() below simply returns
# (err, output) once the root() callback has fired.

use strict;
use warnings;
use Exporter 'import';
use Carp qw( croak );
use Text::Nunjucks::Compiler;
use Text::Nunjucks::Runtime;

our @EXPORT_OK = qw( render );

#### stub Environment / Context (k16 not landed yet -- see header comment)

{

  package Test::Nunjucks::Util::_Ctx;
  sub new { my ( $c, $vars ) = @_; bless { vars => { %{ $vars // {} } }, exported => {} }, $c }
  sub lookup        { my ( $s, $n ) = @_; exists $s->{vars}{$n} ? $s->{vars}{$n} : undef }
  sub set_variable  { my ( $s, $n, $v ) = @_; $s->{vars}{$n} = $v; return }
  sub get_variables { $_[0]->{vars} }
  sub add_export    { my ( $s, $n ) = @_; $s->{exported}{$n} = 1; return }
}
{

  package Test::Nunjucks::Util::_Env;
  sub new        { my ( $c, %a ) = @_; bless { opts => $a{opts} // {}, filters => $a{filters} // {}, tests => $a{tests} // {} }, $c }
  sub opts       { $_[0]->{opts} }
  sub get_filter { my ( $s, $n ) = @_; $s->{filters}{$n} // croak( 'no filter: ' . $n ) }
  sub get_test   { my ( $s, $n ) = @_; $s->{tests}{$n}   // croak( 'no test: ' . $n ) }
}

#### render(template, ctx, opts) -> (err, output)
#
# JS: render(str, ctx, opts, env, cb) constructs Environment+Template and
# calls t.render(ctx, cb); cb(err, res) throws err (unless opts.noThrow) or
# hands (err, normEOL(res)) to the caller. Ported as a direct (err, output)
# return -- see the file header for why no callback/done plumbing is needed;
# the CPS callback below still runs, it is just guaranteed synchronous here.
sub render {
  my ( $template, $ctx, $opts ) = @_;
  $opts = { %{ $opts // {} } };
  $ctx  //= {};

  my $no_throw = delete $opts->{noThrow};
  $opts->{autoescape} = 1 unless exists $opts->{autoescape};

  my $src = eval { Text::Nunjucks::Compiler->compile( $template, [], undef, undef, $opts ) };
  if ( my $e = $@ ) {
    croak $e unless $no_throw;
    return ( $e, undef );
  }

  my $props = eval $src;    ## no critic (ProhibitStringyEval)
  croak "emitted Perl failed to eval:\n$@\n--- SOURCE ---\n$src\n" if $@;

  my $env     = Test::Nunjucks::Util::_Env->new( opts => $opts );
  my $context = Test::Nunjucks::Util::_Ctx->new($ctx);
  my $frame   = Text::Nunjucks::Runtime->Frame->new;
  $frame->top_level(1);

  my ( $out, $err, $called );
  $props->{root}->(
    $env, $context, $frame, 'Text::Nunjucks::Runtime',
    sub {
      my ( $e, $r ) = @_;
      $called = 1;
      $e ? ( $err = $e ) : ( $out = $r );
    }
  );
  croak "root() callback never fired (deferred callback -- not supported by this synchronous harness)"
    unless $called;

  croak $err if $err && !$no_throw;
  return ( $err, $out );
}

1;
