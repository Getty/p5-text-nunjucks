package Text::Nunjucks;
# ABSTRACT: Nunjucks templating engine, ported 1:1 from the JavaScript original

our $VERSION = '0.001';

use strict;
use warnings;

1;

__END__

=synopsis

    use strict;
    use warnings;
    use Text::Nunjucks::Environment;

    my $env = Text::Nunjucks::Environment->new( [], { trimBlocks => 1 } );

    print $env->render_string(
      "Hello {{ name | title }}\n"
        . "{% for item in items %}\n"
        . "- {{ item | upper }}\n"
        . "{% endfor %}",
      { name => 'world', items => [ 'a', 'b<c' ] },
    );

This prints

    Hello World
    - A
    - B&lt;C

=cut

=description

Text::Nunjucks is a 1:1 Perl port of Nunjucks v3.2.4
(L<https://mozilla.github.io/nunjucks/>), Mozilla's templating engine for
JavaScript: the same template, the same context and the same options give the
same output, byte for byte, and the same error messages as the JavaScript
original. Autoescaping is on by default, as in Nunjucks. The template language
is Nunjucks' own, so its documentation applies as it stands: see
L<https://mozilla.github.io/nunjucks/templating.html> for the tags, the
built-in filters, the C<is> tests and the global functions (C<range>,
C<cycler>, C<joiner>). A deliberate difference from upstream is a recorded decision; any other
difference is a bug.

This module is the distribution's front page and loads no code of its own. The
engine is used through L<Text::Nunjucks::Environment>: construct an
Environment with the loaders and options you want, register your own filters,
tests and globals on it, and render with C<render> (a template looked up
through a loader) or C<render_string> (a template given as a string). Template
context is a plain hash reference. A Perl C<undef> is the template's
C<undefined> and the object C<< Text::Nunjucks::Runtime->None >> is its C<null>.

=head2 The public classes

=over 4

=item L<Text::Nunjucks::Environment>

The engine's entry point: loaders, options, filters, tests, globals,
extensions, C<render>, C<render_string> and C<get_template>. The same file also
defines L<Text::Nunjucks::Template> (a compiled template, the object
C<get_template> returns and the one that does the rendering) and
C<Text::Nunjucks::Context> (the per-render bookkeeping, used by the engine and
not meant for callers). C<Text::Nunjucks::Template> has no file of its own:
load it by loading C<Text::Nunjucks::Environment>.

=item L<Text::Nunjucks::Loader>

The base class a template loader extends, and the contract a custom loader
fulfils.

=item L<Text::Nunjucks::Loader::FileSystem>

Loads templates from directories on disk.

=item L<Text::Nunjucks::Loader::Precompiled>

Serves templates from a hash of already compiled template objects.

=item L<Text::Nunjucks::EmitterObj>

The C<on> / C<emit> role loaders and the Environment share.

=item L<Text::Nunjucks::Lib::TemplateError> and L<Text::Nunjucks::Lib::Error>

The error objects a failed render throws or passes to its callback.

=back

The remaining modules (L<Text::Nunjucks::Lexer>, L<Text::Nunjucks::Parser>,
L<Text::Nunjucks::Nodes>, L<Text::Nunjucks::Transformer>,
L<Text::Nunjucks::Compiler>, L<Text::Nunjucks::Runtime>,
L<Text::Nunjucks::Lib>, L<Text::Nunjucks::Filters>, L<Text::Nunjucks::Tests>
and L<Text::Nunjucks::Globals>) are the engine itself, each a port of the
upstream file of the same name. They are documented for orientation only and
are not a stable interface.

=cut

=seealso

L<Text::Nunjucks::Environment>, L<https://mozilla.github.io/nunjucks/>

=cut
