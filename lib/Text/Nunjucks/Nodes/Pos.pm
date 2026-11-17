package Text::Nunjucks::Nodes::Pos;
# ABSTRACT: AST node Pos (fields target), ported from nodes.js

our $VERSION = '0.002';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::UnaryOp';

# nodes.js: const Pos = UnaryOp.extend('Pos');
# No {fields}: the field list and its accessors are inherited
# from UnaryOp (target).

sub typename { 'Pos' }

1;

__END__

=description

Engine-internal: the C<Pos> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut
