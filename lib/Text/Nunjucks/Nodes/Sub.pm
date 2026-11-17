package Text::Nunjucks::Nodes::Sub;
# ABSTRACT: AST node Sub (fields left, right), ported from nodes.js

our $VERSION = '0.002';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::BinOp';

# nodes.js: const Sub = BinOp.extend('Sub');
# No {fields}: the field list and its accessors are inherited
# from BinOp (left, right).

sub typename { 'Sub' }

1;

__END__

=description

Engine-internal: the C<Sub> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut
