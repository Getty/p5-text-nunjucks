package Text::Nunjucks::Nodes::Super;
# ABSTRACT: AST node Super (fields blockName, symbol), ported from nodes.js

our $VERSION = '0.002';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::Node';

# nodes.js: const Super = Node.extend('Super', { fields: ['blockName', 'symbol'] });

has blockName => ( is => 'rw' );
has symbol    => ( is => 'rw' );

sub typename { 'Super' }
sub fields   { [ 'blockName', 'symbol' ] }

1;

__END__

=description

Engine-internal: the C<Super> node of the template AST that
L<Text::Nunjucks::Transformer> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut
