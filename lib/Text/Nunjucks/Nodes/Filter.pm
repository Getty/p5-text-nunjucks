package Text::Nunjucks::Nodes::Filter;
# ABSTRACT: AST node Filter (fields name, args), ported from nodes.js

our $VERSION = '0.001';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::FunCall';

# nodes.js: const Filter = FunCall.extend('Filter');
# No {fields}: the field list and its accessors are inherited
# from FunCall (name, args).

sub typename { 'Filter' }

1;

__END__

=description

Engine-internal: the C<Filter> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut
