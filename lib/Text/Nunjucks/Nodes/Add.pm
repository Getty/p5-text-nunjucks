package Text::Nunjucks::Nodes::Add;
# ABSTRACT: AST node Add (fields left, right), ported from nodes.js

our $VERSION = '0.001';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::BinOp';

# nodes.js: const Add = BinOp.extend('Add');
# No {fields}: the field list and its accessors are inherited
# from BinOp (left, right).

sub typename { 'Add' }

1;

__END__

=description

Engine-internal: the C<Add> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut
