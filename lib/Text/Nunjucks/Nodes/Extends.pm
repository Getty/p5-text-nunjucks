package Text::Nunjucks::Nodes::Extends;
# ABSTRACT: AST node Extends (fields template), ported from nodes.js

our $VERSION = '0.001';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::TemplateRef';

# nodes.js: const Extends = TemplateRef.extend('Extends');
# No {fields}: the field list and its accessors are inherited
# from TemplateRef (template).

sub typename { 'Extends' }

1;

__END__

=description

Engine-internal: the C<Extends> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut
