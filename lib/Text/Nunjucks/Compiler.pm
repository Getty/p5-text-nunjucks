package Text::Nunjucks::Compiler;
# ABSTRACT: 1:1 port of Nunjucks src/compiler.js -- emits Perl source

our $VERSION = '0.001';

use strict;
use warnings;
use Scalar::Util qw( blessed );
use Text::Nunjucks::Parser;
use Text::Nunjucks::Transformer;
use Text::Nunjucks::Compiler::Compiler;

# 1:1 port of upstream src/compiler.js. compiler.js exports { compile, Compiler };
# the port mirrors that shape the way Parser.pm mirrors parser.js: the module
# functions live here on Text::Nunjucks::Compiler (compile(), and
# compiler_class() for the exported Compiler class), while the class itself is
# the Moo class Text::Nunjucks::Compiler::Compiler in its own file (ADR 0002,
# object.js not ported; ADR 0020).
#
# The class carries the emission rules: what compiler.js's JavaScript output
# becomes in Perl is set out at the top of Text/Nunjucks/Compiler/Compiler.pm.

#### module.exports.compile -- compile(src, asyncFilters, extensions, name, opts)

sub compile {
  my ( $self, $src, $async_filters, $extensions, $name, $opts ) = @_;
  $opts //= {};

  my $c = $self->compiler_class->new(
    template_name      => $name,
    throw_on_undefined => $opts->{throwOnUndefined},
  );

  # Run the extension preprocessors against the source.
  my $processed_src = $src;
  for my $ext ( @{ $extensions || [] } ) {
    my $pre = $self->_ext_preprocess($ext);
    $processed_src = $pre->($processed_src) if $pre;
  }

  $c->compile(
    $self->transformer->transform(
      $self->parser->parse( $processed_src, $extensions, $opts ),
      $async_filters,
      $name
    )
  );
  return $c->get_code;
}

# Collaborators named once, reached through the invocant (house rule).
sub parser         { 'Text::Nunjucks::Parser' }
sub transformer    { 'Text::Nunjucks::Transformer' }
sub compiler_class { 'Text::Nunjucks::Compiler::Compiler' }

# ext.preprocess -- extension representation is open (k8/k22); read it as an
# object method or a hash coderef, else nothing, and report.
sub _ext_preprocess {
  my ( $self, $ext ) = @_;
  return undef unless defined $ext && ref $ext;
  if ( blessed($ext) ) {
    return $ext->can('preprocess') ? sub { $ext->preprocess(@_) } : undef;
  }
  return ( ref $ext eq 'HASH' && $ext->{preprocess} ) ? $ext->{preprocess} : undef;
}


1;

__END__

=head1 DESCRIPTION

Engine-internal: this module is a stage of the template pipeline, used by
L<Text::Nunjucks::Environment>, and not an interface for applications.

A 1:1 port of Nunjucks C<src/compiler.js>. Unlike every other ported module,
this one emits B<Perl> source (upstream emits JavaScript), keeping upstream's
CPS shape (ADR 0003). C<< Text::Nunjucks::Compiler->compile($src, $async_filters,
$extensions, $name, $opts) >> returns a string that, when C<eval>ed, yields a
hashref C<< { root => \&root, b_<name> => \&b_<name>, ... } >>. The class
that walks the AST and emits the code is L<Text::Nunjucks::Compiler::Compiler>
(reachable as C<< Text::Nunjucks::Compiler->compiler_class >>, mirroring
upstream's exported C<Compiler>).

The emitted code calls into C<$runtime> (Text::Nunjucks::Runtime, class-method
API) for every operator and value operation, C<$env> / C<$context> for the
environment surface (implemented by Text::Nunjucks::Environment), and uses
C<$frame> / C<$cb> per the callback protocol.

=cut
