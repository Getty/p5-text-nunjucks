package Text::Nunjucks::Nodes::Dict;
# ABSTRACT: AST node Dict (fields children), ported from nodes.js

our $VERSION = '0.002';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::NodeList';

# nodes.js: const Dict = NodeList.extend('Dict');
# No {fields}: the field list and its accessors are inherited
# from NodeList (children).

sub typename { 'Dict' }

1;

__END__

=description

Engine-internal: the C<Dict> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut
