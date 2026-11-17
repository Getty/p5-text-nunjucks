package Text::Nunjucks::Nodes::Capture;
# ABSTRACT: AST node Capture (fields body), ported from nodes.js

our $VERSION = '0.001';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::Node';

# nodes.js: const Capture = Node.extend('Capture', { fields: ['body'] });

has body => ( is => 'rw' );

sub typename { 'Capture' }
sub fields   { [ 'body' ] }

1;

__END__

=description

Engine-internal: the C<Capture> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut
