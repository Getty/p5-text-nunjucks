package Text::Nunjucks::Nodes::NodeList;
# ABSTRACT: AST node holding a list of child nodes (nodes.js class NodeList)

our $VERSION = '0.001';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::Node';

# upstream: class NodeList extends Node

has children => ( is => 'rw' );

sub typename { 'NodeList' }
sub fields   { ['children'] }

# init(lineno, colno, nodes) -> super.init(lineno, colno, nodes || [])
sub BUILDARGS {
  my ( $class, $lineno, $colno, $nodes ) = @_;
  return $class->_field_args( $lineno, $colno, $nodes || [] );
}

sub add_child {
  my ( $self, $node ) = @_;
  push @{ $self->children }, $node;
}

1;

__END__

=description

Engine-internal: the node of the template AST in L<Text::Nunjucks::Nodes> that
holds an ordered list of child nodes in C<children>, and the parent of C<Root>,
C<Group>, C<Array>, C<Dict>, C<Output> and C<KeywordArgs>.

=cut
