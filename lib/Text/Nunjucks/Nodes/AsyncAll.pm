package Text::Nunjucks::Nodes::AsyncAll;
# ABSTRACT: AST node AsyncAll (fields arr, name, body, else_), ported from nodes.js

our $VERSION = '0.001';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::For';

# nodes.js: const AsyncAll = For.extend('AsyncAll');
# No {fields}: the field list and its accessors are inherited
# from For (arr, name, body, else_).

sub typename { 'AsyncAll' }

1;

__END__

=description

Engine-internal: the C<AsyncAll> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut
