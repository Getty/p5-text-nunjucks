package Text::Nunjucks::Nodes::For;
# ABSTRACT: AST node For (fields arr, name, body, else_), ported from nodes.js

our $VERSION = '0.002';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::Node';

# nodes.js: const For = Node.extend('For', { fields: ['arr', 'name', 'body', 'else_'] });

has arr   => ( is => 'rw' );
has name  => ( is => 'rw' );
has body  => ( is => 'rw' );
has else_ => ( is => 'rw' );

sub typename { 'For' }
sub fields   { [ 'arr', 'name', 'body', 'else_' ] }

1;

__END__

=description

Engine-internal: the C<For> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut
