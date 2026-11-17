package Text::Nunjucks::Nodes::Array;
# ABSTRACT: AST node Array (fields children), ported from nodes.js

our $VERSION = '0.001';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::NodeList';

# nodes.js: const ArrayNode = NodeList.extend('Array');
# No {fields}: the field list and its accessors are inherited
# from NodeList (children).

sub typename { 'Array' }

1;

__END__

=description

Engine-internal: the C<Array> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut
