#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Scalar::Util qw( blessed );
use JSON::MaybeXS ();
use Path::Tiny qw( path );

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
sub ast_dump {
  my ($n) = @_;
  if ( blessed($n) && $n->can('typename') && $n->can('fields') ) {
    my %out = ( type => $n->typename, lineno => $n->lineno, colno => $n->colno );
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

# Replaying render needs the Environment/loader/callback surface that ADR 0003
# (CPS) and tickets k16/k20 define: an in-memory loader for cases that carry
# "templates" + "render", opts and context threaded in, jinjaCompat toggled,
# and the render callback resolved. That API does not exist yet, so render
# cases stay TODO. When it lands, set render_supported to detect it and wire
# run_render to the oracle's render() semantics (maint/oracle.js).
sub render_supported { 0 }

sub run_render {
  die "render-mode replay is not wired yet (render API lands in k16/k20)\n";
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
