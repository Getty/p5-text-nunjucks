package Text::Nunjucks::Nodes::UnaryOp;
# ABSTRACT: AST node UnaryOp (fields target), ported from nodes.js

our $VERSION = '0.002';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::Node';

# nodes.js: const UnaryOp = Node.extend('UnaryOp', { fields: ['target'] });

has target => ( is => 'rw' );

sub typename { 'UnaryOp' }
sub fields   { [ 'target' ] }

1;

__END__

=description

Engine-internal: the C<UnaryOp> node of the template AST, the parent of the
concrete nodes that carry its fields; see L<Text::Nunjucks::Nodes>.

=cut
