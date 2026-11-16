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

=head1 STATUS

This is release 0.001. The entry point is L<Text::Nunjucks::Environment>:
construct one with C<< Text::Nunjucks::Environment->new($loaders, \%opts) >> and call
C<render>, C<render_string> or C<get_template> on it. Perl 5.40 or newer is
required, and the paths and file handling are POSIX only (see
L</DIFFERENCES FROM NUNJUCKS>).

B<Not in 0.001.> The top-level API of Nunjucks' C<index.js> (the package-level
C<configure>, C<reset>, C<compile>, C<render> and C<render_string> over a default
environment) does not exist: C<Text::Nunjucks> loads no code and has no
functions or class methods. Its Perl calling convention is undecided (k101, k20).
Also not ported: jinja-compat (k22), C<precompile> and its CLI (k23),
C<NodeResolveLoader>, C<WebLoader>, chokidar C<watch> (a truthy C<watch> dies
with C<watch requires chokidar to be installed>, ADR 0018) and the browser
bundles. The Perl shape of an extension object (C<add_extension>) is not settled
(k102).

=cut

=head1 DIFFERENCES FROM NUNJUCKS

Same template, same context, same options give the same bytes and the same error
message, except for what is listed here. The decisions are in F<docs/adr/>
(L<https://github.com/Getty/p5-text-nunjucks/tree/main/docs/adr>); C<ADR NNNN>
names one, C<kNN> is an open card on the project board for a divergence that has
not been decided or fixed yet.

=head2 Decided differences

=over 4

=item Values and kinds (ADR 0001, 0006, 0007)

A value's kind comes from the Perl scalar itself: a number you built as a number
is a number, a numeric string is a string, so C<"1"> and C<1> behave as in
JavaScript. Data from a JSON module arrives right; build values with C<0+$x> or
C<"$x"> when in doubt. A Perl C<undef> is the template's C<undefined>;
C<null> is the singleton C<< Text::Nunjucks::Runtime->None >> (a JSON C<null> in
the context is turned into it). Numbers are printed as JavaScript prints them.

=item Object key order (ADR 0011)

Dicts written in a template keep their insertion order. A plain Perl hash passed
in the context has no order, so it iterates sorted by key. Use
L<Hash::Ordered> for an order you control; C<Tie::IxHash> is not honoured (k78).

=item Strings are UTF-16 (ADR 0012)

String operations count in UTF-16 code units, as JavaScript does. Templates,
context and results are decoded character strings, and loaders decode UTF-8.

=item Native methods (ADR 0008)

Only a curated set of the JavaScript C<String>, C<Array> and C<Number> methods is
available from a template (C<length>, C<toUpperCase>, C<replace>, C<slice>,
C<split>, C<indexOf>, C<join>, C<push>, C<sort>, C<toFixed> and similar). The
mutators change your Perl data in place, as they do in JavaScript. Missing: a
template-level C<toString()>, Array C<map>/C<filter>/C<reduce>, C<toSorted>,
C<splice> (k70, k84, k86).

=item Calling Perl code (ADR 0009, 0016)

Keyword arguments arrive as a trailing hash reference carrying a marker. A Perl
coderef called from a template gets no C<this>; an object's method called as
C<obj.method()> gets the object. C<{{ obj.method }}> without parentheses
I<calls> the method and renders its result, where JavaScript renders the
function's source (k47).

=item Errors (ADR 0010)

JavaScript's built-in errors are one class with a C<name> and a C<message>; the
messages are those of the original.

=item Regular expressions (ADR 0005, 0013)

A regex literal becomes a C<Text::Nunjucks::Runtime::Regex> object. A pattern
Perl cannot express is refused when the template is compiled, never translated
wrongly. C<\s>, C<\d> and C<\w> follow ECMAScript's sets, with open problems:
C<\d>/C<\w>/C<\s> under the C<u> flag (k45, k49), C<^>/C<$>/C<.> and JavaScript
line terminators (k66).

=item Names that exist on JavaScript's Object.prototype (ADR 0014)

A template variable resolves only to something you set, as a global or an own key
of the context. C<toString>, C<constructor>, C<hasOwnProperty> and the like are
not found as variables. The same question for filter and test names, member
reads and the C<groupby> result is open (k87, k81, k89).

=item Sorting (ADR 0017)

C<sort>, C<dictsort> and C<Array.sort> are a port of V8's TimSort, so the order
of equal and inconsistent comparisons matches node's.

=item Scope and platform (ADR 0018)

C<FileSystemLoader> and C<PrecompiledLoader> are ported
(L<Text::Nunjucks::Loader::FileSystem>, L<Text::Nunjucks::Loader::Precompiled>).
C<NodeResolveLoader>, C<WebLoader>, chokidar C<watch> and the browser branches of
C<Environment> are out of scope. Node's C<path> and C<fs> are ported as their
POSIX behaviour: C</> is the only separator, so Windows paths do not work (k97,
k112).

=item The random filter

C<random> uses Perl's C<rand>, upstream V8's C<Math.random>: different
generators, so the output is not comparable either way.

=item Upstream bugs kept (ADR 0004)

An upstream bug is ported, not fixed: the C<FileSystemLoader> containment check
is a string-prefix test and serves C<../views2/x.njk> for search path C<views>
(k95); the lexer's C<back()> reads a field that does not exist, in a branch that
cannot be reached (k27); render-time errors report a 0-based line and column
while parse errors are 1-based (k106).

=back

=head2 Open differences

Known, not decided or not fixed yet. Each is a card; none is hidden.

=over 4

=item Decisions waiting for the maintainer

Set and Map as context values, C<new String(...)> wrappers and arrays with own
properties cannot be built from Perl, and a C<toString> member is not honoured
(k44); the Unicode version of case mapping follows the running perl, Unicode 15
on 5.40, not node's (k64); V8's heap and string-length limits are not emulated, so
an exhausting input (C<center(1/0)>) runs until the OS stops it (k69); engine
methods that read C<this>, such as C<cycler>'s C<next> and C<reset>, behave
differently when called without C<memberLookup> (k93); a loader object that is
not a C<Text::Nunjucks::Loader> subclass and has only C<get_source> is not
accepted (k94); a render that defers with no callback returns C<undef> silently,
as upstream returns C<null> (k104, the ADRs 0003 and 0009 say it dies); the
print format of C<print_nodes> is not byte-identical (k26); the extension object
shape (k102); the top-level API (k101).

=item Differences in what a template can see or do

A malformed C<from X import 3> succeeds where upstream throws a raw
C<TypeError> (k29); an integer literal of 300 or more digits does not compile
(k40); the C<in> operator converts its key the Perl way (C<true>, C<null>,
arrays) (k54) and on a C<SafeString> checks own keys only (k73); C<split> and
C<replace> with a regex argument stringify it (k57); regex C<exec> with C<g> loses
the context for lookahead, C<^> and C<\b> (k67); code points are matched where
JavaScript has UTF-16 units, in the lexer's column and in regexes (k52, k53,
k62); iterating a string or a C<SafeString> with C<for> (k59, k60) and
C<asyncEach> over a string (k58) fail or iterate differently; a single-name
C<for> reads C<arr.length> once (k61); calling a non-callable member says
C<undefined or falsey> where JavaScript says C<not a function> (k65, k91);
C<{% set x.b = 1 %}> dies with a Perl error (k82); C<is not (test)> with a
parenthesised name crashes (k90); C<.val> on a C<SafeString> reads empty (k72);
C<SafeString-E<gt>new(5)> returns the value (k75); a C<__proto__> key in a dict
literal is an own key (k89); a macro's C<length> and C<name> read undefined
(k88); C<o.f> yields the same function each time, not a new closure (k92); a
keyword-argument object returned to a template is opaque (k79); an
engine-built loop object and import namespace iterate sorted, not in insertion
order (k80); C<groupby> with a key such as C<toString> groups instead of
throwing (k81); C<autoescape> uses Perl truthiness, so C<'0'> turns it off (k103);
C<Math.pow> and C<**> differ for exact-tie powers above 2**53 (k74); the
template-name error message joins a non-string name the Perl way (k99);
C<Template-E<gt>new> with a C<Hash::Ordered> source dies (k71); JSON integers
beyond 64 bits arrive as strings in the corpus harness (k77).

=back

=cut

=head1 LIMITATIONS

=over 4

=item Memory

Keep one long-lived L<Text::Nunjucks::Environment>. A cached template holds its
Environment, so an Environment with a caching loader is never freed (k96); a
render that uses C<include>, C<asyncEach> or C<super()>, or macros and C<caller>
that read outer names, keeps its context alive (k107, k108, k109).

=item Speed

Compiling costs about 130 microseconds per source character (k63), so reuse
compiled templates and the Environment's cache. Rendering a 1000-row table is
about 35 times slower than node; C<replace>, C<title> and the number-to-string
step are slow on large input (k68, k85).

=item Unicode

Case mapping follows the Unicode tables of the running perl (k64).

=back

=cut

=head1 SECURITY

L<Text::Nunjucks::Loader::FileSystem> keeps upstream's containment check, a
string-prefix test: with search path C<views> the name C<../views2/x.njk> is
served, as is the sibling file C<../views.env>. The search path C<.> serves the
current directory and its siblings, and symlinks are followed. Never pass
template names you do not control to C<render> or C<get_template>, and never
render a template you do not trust: a template is code (k95).

=cut

=seealso

L<Text::Nunjucks::Environment>, L<https://mozilla.github.io/nunjucks/>

=cut
