package Text::Nunjucks::Nodes::Macro;
# ABSTRACT: AST node Macro (fields name, args, body), ported from nodes.js

our $VERSION = '0.001';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::Node';

# nodes.js: const Macro = Node.extend('Macro', { fields: ['name', 'args', 'body'] });

has name => ( is => 'rw' );
has args => ( is => 'rw' );
has body => ( is => 'rw' );

sub typename { 'Macro' }
sub fields   { [ 'name', 'args', 'body' ] }

1;

__END__

=description

Engine-internal: the C<Macro> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut
