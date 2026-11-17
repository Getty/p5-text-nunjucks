package Text::Nunjucks::Nodes::BinOp;
# ABSTRACT: AST node BinOp (fields left, right), ported from nodes.js

our $VERSION = '0.001';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::Node';

# nodes.js: const BinOp = Node.extend('BinOp', { fields: ['left', 'right'] });

has left  => ( is => 'rw' );
has right => ( is => 'rw' );

sub typename { 'BinOp' }
sub fields   { [ 'left', 'right' ] }

1;

__END__

=description

Engine-internal: the C<BinOp> node of the template AST, the parent of the
concrete nodes that carry its fields; see L<Text::Nunjucks::Nodes>.

=cut
