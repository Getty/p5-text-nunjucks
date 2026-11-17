package Text::Nunjucks::Nodes::FilterAsync;
# ABSTRACT: AST node FilterAsync (fields name, args, symbol), ported from nodes.js

our $VERSION = '0.001';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::Filter';

# nodes.js: const FilterAsync = Filter.extend('FilterAsync', { fields: ['name', 'args', 'symbol'] });
# name and args are inherited from Filter; the accessor for symbol is new.

has symbol => ( is => 'rw' );

sub typename { 'FilterAsync' }
sub fields   { [ 'name', 'args', 'symbol' ] }

1;

__END__

=description

Engine-internal: the C<FilterAsync> node of the template AST that
L<Text::Nunjucks::Transformer> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut
