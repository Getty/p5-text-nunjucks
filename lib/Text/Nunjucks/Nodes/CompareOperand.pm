package Text::Nunjucks::Nodes::CompareOperand;
# ABSTRACT: AST node CompareOperand (fields expr, type), ported from nodes.js

our $VERSION = '0.002';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::Node';

# nodes.js: const CompareOperand = Node.extend('CompareOperand', { fields: ['expr', 'type'] });

has expr => ( is => 'rw' );
has type => ( is => 'rw' );

sub typename { 'CompareOperand' }
sub fields   { [ 'expr', 'type' ] }

1;

__END__

=description

Engine-internal: the C<CompareOperand> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut
