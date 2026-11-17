package Text::Nunjucks::Nodes::FromImport;
# ABSTRACT: AST node FromImport (fields template, names, withContext), ported from nodes.js

our $VERSION = '0.001';

use Moo;
use Text::Nunjucks::Nodes::NodeList;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::Node';

# upstream: class FromImport extends Node -- custom init, declared in nodes.js
# between Import and FunCall.

has template    => ( is => 'rw' );
has names       => ( is => 'rw' );
has withContext => ( is => 'rw' );

sub typename { 'FromImport' }
sub fields   { [ 'template', 'names', 'withContext' ] }

# init(lineno, colno, template, names, withContext)
#  -> super.init(lineno, colno, template, names || new NodeList(), withContext)
sub BUILDARGS {
  my ( $class, $lineno, $colno, $template, $names, $withContext ) = @_;
  return $class->_field_args(
    $lineno, $colno,
    $template,
    ( $names || $class->_node_class('NodeList')->new ),
    $withContext
  );
}

1;

__END__

=description

Engine-internal: the C<FromImport> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut
