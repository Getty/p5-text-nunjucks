#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Scalar::Util qw( blessed );
use JSON::MaybeXS ();
use Path::Tiny qw( path );
use builtin ();

no warnings 'experimental::builtin';

# render mode (k16): an in-memory loader mirroring maint/oracle.js's MemoryLoader
# (getSource -> {src, path, noCache}). Defined only if the Loader base is present
# so the file still loads on a port where render is not yet implemented.
BEGIN {
  if ( eval { require Text::Nunjucks::Loader; 1 } ) {
    eval q{
      package Corpus::MemoryLoader;
      use Moo;
      extends 'Text::Nunjucks::Loader';
      has templates => ( is => 'ro', default => sub { {} } );
      sub get_source {
        my ( $self, $name ) = @_;
        return undef unless exists $self->templates->{$name};
        return { src => $self->templates->{$name}, path => $name, noCache => 1 };
      }
      1;
    } or die $@;
  }
}

# Replay every t/corpus/*.json case against the Perl port, dispatched by the
# case's mode (lex / parse / render). Each case carries the oracle's result as
# "expected" (ok/output or ok/error), written by maint/corpus-regen and never
# typed by hand. Until the port implements a mode, its cases run as TODO -- so
# this file stays green on an unimplemented port and turns real as each stage
# lands. A TODO test that starts passing is a signal to drop the TODO.

my $DECODE = JSON::MaybeXS->new( utf8 => 1, allow_nonref => 1 );
my $CANON  = JSON::MaybeXS->new(
  canonical    => 1,
  convert_blessed => 1,
  allow_nonref => 1,
  utf8         => 0,
);

# Compare two result structures by their canonical JSON. Both sides go through
# the same encoder, so booleans, key order and undef->null normalise the same
# way on each side and the diff Test::More prints is readable.
sub canon { $CANON->encode( $_[0] ) }

sub true  { JSON::MaybeXS::true() }
sub false { JSON::MaybeXS::false() }

# Map a caught exception to the oracle's {ok:false, error:{name,message}} shape.
# A Text::Nunjucks error object (Lib::TemplateError, per the porting map) knows
# its own name and message; anything else is a real bug in the port, so it is
# rethrown to fail the test loudly rather than be dressed up as an error result.
sub error_result {
  my ($err) = @_;
  if ( blessed($err) && $err->can('name') && $err->can('message') ) {
    return { ok => false, error => { name => $err->name, message => $err->message } };
  }
  die $err;
}

#### lex mode -- lexer.lex(template, opts).nextToken()  (upstream oracle.js)

sub lex_supported {
  eval { require Text::Nunjucks::Lexer; 1 } && Text::Nunjucks::Lexer->can('lex');
}

sub run_lex {
  my ($case) = @_;
  my @tokens;
  my $ok = eval {
    my $t = Text::Nunjucks::Lexer->lex( $case->{template}, $case->{opts} );
    while ( my $tok = $t->next_token ) {
      push @tokens, {
        type   => $tok->type,
        value  => $tok->value,
        lineno => $tok->lineno,
        colno  => $tok->colno,
      };
    }
    1;
  };
  return $ok ? { ok => true, output => \@tokens } : error_result($@);
}

#### parse mode -- parser.parse(template, [], opts) dumped as the oracle's AST

sub parse_supported {
  eval { require Text::Nunjucks::Parser; require Text::Nunjucks::Nodes; 1 }
    && Text::Nunjucks::Parser->can('parse');
}

# The Perl-side dump shape, equal to the oracle JSON (maint/oracle.js `ast`):
#   node  -> { type => typename, lineno, colno, <fields in nodes.js order> }
#   array -> map the dump over its elements
#   regex -> { regex => source, flags }         (regex mapping is decided in k7)
#   else  -> the value as-is; undef encodes to null, like the oracle's undefined
# A node is anything that answers ->typename/->fields/->lineno/->colno, which is
# the 1:1 image of `instanceof nodes.Node` without hardcoding the class name.
#
# lineno/colno are emitted only when defined. The oracle serializes with
# JSON.stringify, which drops a key whose value is `undefined`, and some nodes
# legitimately carry undefined positions -- the switch Case (upstream typo:
# parser.js reads tok.line/tok.col, which Token does not have), the call-block's
# appended KeywordArgs and its empty NodeList. A value of 0 is a real position
# and stays; only genuine undef is dropped, matching JSON.stringify exactly.
sub ast_dump {
  my ($n) = @_;
  if ( blessed($n) && $n->can('typename') && $n->can('fields') ) {
    my %out = ( type => $n->typename );
    $out{lineno} = $n->lineno if defined $n->lineno;
    $out{colno}  = $n->colno  if defined $n->colno;
    for my $f ( @{ $n->fields } ) {
      $out{$f} = ast_dump( $n->$f );
    }
    return \%out;
  }
  if ( ref $n eq 'ARRAY' ) {
    return [ map { ast_dump($_) } @$n ];
  }
  if ( ref $n eq 'Regexp' ) {
    my ( $source, $flags ) = re::regexp_pattern($n);
    return { regex => $source, flags => $flags };
  }
  return $n;
}

sub run_parse {
  my ($case) = @_;
  my $tree;
  my $ok = eval { $tree = Text::Nunjucks::Parser->parse( $case->{template}, [], $case->{opts} ); 1 };
  return $ok ? { ok => true, output => ast_dump($tree) } : error_result($@);
}

#### render mode -- env.renderString / env.render through the callback API

# The render surface (Environment/Context/Template + the callback protocol of
# ADR 0003) lands with k16. Cases carry an optional in-memory "templates" bag,
# a "render" name (else "template" is renderString'd), a "context" and "opts".
# jinjaCompat is not modelled yet (no corpus case sets it); assert it if seen.
sub render_supported {
  eval { require Text::Nunjucks::Environment; 1 } && Text::Nunjucks::Environment->can('new');
}

# Normalise a JSON-decoded value to the port's value model at the context
# boundary (the oracle hands upstream real JS values): JSON booleans become
# native booleans (ADR 0001) and JSON null becomes the None sentinel (ADR 0006).
# Numbers/strings pass through; containers are rebuilt so caller hashes stay
# plain (ADR 0011 gives them key-sorted iteration, not this harness's concern).
sub normalize {
  my ($v) = @_;
  return Text::Nunjucks::Runtime->None if !defined $v;            # JS null
  if ( blessed($v) ) {
    return ( $v ? builtin::true() : builtin::false() ) if $v->isa('JSON::PP::Boolean');
    return $v;
  }
  my $r = ref $v;
  return { map { $_ => normalize( $v->{$_} ) } keys %$v } if $r eq 'HASH';
  return [ map { normalize($_) } @$v ] if $r eq 'ARRAY';
  return $v;
}

sub run_render {
  my ($case) = @_;
  die "jinjaCompat render cases are not modelled yet\n" if $case->{jinjaCompat};

  require Text::Nunjucks::Runtime;
  my $loader = Corpus::MemoryLoader->new( templates => $case->{templates} // {} );
  my $opts   = defined $case->{opts}    ? normalize( $case->{opts} )    : undef;
  my $ctx    = defined $case->{context} ? normalize( $case->{context} ) : {};
  my $env    = Text::Nunjucks::Environment->new( [$loader], $opts );

  my ( $err, $res, $called );
  my $cb = sub { ( $err, $res ) = @_; $called = 1; };

  if ( defined $case->{render} ) {
    $env->render( $case->{render}, $ctx, $cb );
  }
  else {
    $env->render_string( $case->{template}, $ctx, $cb );
  }

  die "render callback was never invoked (template deferred without resolving)\n"
    unless $called;
  return error_result($err) if $err;
  return { ok => true, output => $res };
}

my %MODE = (
  lex    => { supported => \&lex_supported,    run => \&run_lex,    ticket => 'k10 (lexer)' },
  parse  => { supported => \&parse_supported,  run => \&run_parse,  ticket => 'k11/k12 (nodes/parser)' },
  render => { supported => \&render_supported, run => \&run_render, ticket => 'k16/k20 (environment/API)' },
);

my $corpus = path(__FILE__)->parent->child('corpus');
my @files  = sort $corpus->children(qr/\.json$/);

plan skip_all => "no corpus files in $corpus" unless @files;

for my $file (@files) {
  my $rel   = $file->basename;
  my $cases = $DECODE->decode( $file->slurp_raw );

  for my $case (@$cases) {
    my $mode = $case->{mode} // 'render';
    my $m    = $MODE{$mode} or do { fail("$rel: $case->{name} [unknown mode $mode]"); next };
    my $title = "$rel: " . ( $case->{name} // '(unnamed)' ) . " [$mode]";

    unless ( $m->{supported}->() ) {
      TODO: {
        local $TODO = "$mode mode not implemented yet -- $m->{ticket}";
        ok( 0, $title );
      }
      next;
    }

    my $got = eval { $m->{run}->($case) };
    if ( my $err = $@ ) {
      fail($title);
      diag("runner died: $err");
      next;
    }
    is( canon($got), canon( $case->{expected} ), $title );
  }
}

done_testing;
