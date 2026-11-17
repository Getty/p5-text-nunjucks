package Text::Nunjucks::Nodes::Block;
# ABSTRACT: AST node Block (fields name, body), ported from nodes.js

our $VERSION = '0.001';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::Node';

# nodes.js: const Block = Node.extend('Block', { fields: ['name', 'body'] });

has name => ( is => 'rw' );
has body => ( is => 'rw' );

sub typename { 'Block' }
sub fields   { [ 'name', 'body' ] }

1;

__END__

=description

Engine-internal: the C<Block> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut
