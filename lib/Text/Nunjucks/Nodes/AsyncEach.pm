package Text::Nunjucks::Nodes::AsyncEach;
# ABSTRACT: AST node AsyncEach (fields arr, name, body, else_), ported from nodes.js

our $VERSION = '0.002';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::For';

# nodes.js: const AsyncEach = For.extend('AsyncEach');
# No {fields}: the field list and its accessors are inherited
# from For (arr, name, body, else_).

sub typename { 'AsyncEach' }

1;

__END__

=description

Engine-internal: the C<AsyncEach> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut
