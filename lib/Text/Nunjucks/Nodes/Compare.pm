package Text::Nunjucks::Nodes::Compare;
# ABSTRACT: AST node Compare (fields expr, ops), ported from nodes.js

our $VERSION = '0.002';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::Node';

# nodes.js: const Compare = Node.extend('Compare', { fields: ['expr', 'ops'] });

has expr => ( is => 'rw' );
has ops  => ( is => 'rw' );

sub typename { 'Compare' }
sub fields   { [ 'expr', 'ops' ] }

1;

__END__

=description

Engine-internal: the C<Compare> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut
