package Text::Nunjucks::Nodes::KeywordArgs;
# ABSTRACT: AST node KeywordArgs (fields children), ported from nodes.js

our $VERSION = '0.002';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::Dict';

# nodes.js: const KeywordArgs = Dict.extend('KeywordArgs');
# No {fields}: the field list and its accessors are inherited
# from Dict (children).

sub typename { 'KeywordArgs' }

1;

__END__

=description

Engine-internal: the C<KeywordArgs> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut
