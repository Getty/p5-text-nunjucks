package Text::Nunjucks::Nodes::Caller;
# ABSTRACT: AST node Caller (fields name, args, body), ported from nodes.js

our $VERSION = '0.001';

use Moo;
use namespace::autoclean;

extends 'Text::Nunjucks::Nodes::Macro';

# nodes.js: const Caller = Macro.extend('Caller');
# No {fields}: the field list and its accessors are inherited
# from Macro (name, args, body).

sub typename { 'Caller' }

1;

__END__

=description

Engine-internal: the C<Caller> node of the template AST that
L<Text::Nunjucks::Parser> builds and L<Text::Nunjucks::Compiler> reads; see
L<Text::Nunjucks::Nodes>.

=cut
