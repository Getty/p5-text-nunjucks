package Text::Nunjucks::Nodes::Mul;
# ABSTRACT: AST node Mul (fields left, right), ported from nodes.js

our $VERSION = '0.002';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::BinOp';

# nodes.js: const Mul = BinOp.extend('Mul');
# No {fields}: the field list and its accessors are inherited
# from BinOp (left, right).

sub typename { 'Mul' }

1;

__END__

=description

Engine-internal: the C<Mul> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut
