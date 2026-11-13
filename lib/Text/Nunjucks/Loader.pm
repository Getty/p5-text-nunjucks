package Text::Nunjucks::Loader;
# ABSTRACT: 1:1 port of Nunjucks src/loader.js -- the base Loader (resolve/isRelative)

our $VERSION = '0.001';

use Moo;
with 'Text::Nunjucks::EmitterObj';
use Text::Nunjucks::Lib;
use namespace::autoclean;

# src/loader.js: `module.exports = class Loader extends EmitterObj { resolve;
# isRelative }`. EmitterObj -> the on/emit role (ADR 0002). The concrete
# loaders extend it in their own modules: src/node-loaders.js's FileSystemLoader
# is Text::Nunjucks::Loader::FileSystem, src/precompiled-loader.js's
# PrecompiledLoader is Text::Nunjucks::Loader::Precompiled (ADR 0018).
#
# `cache` is not declared by loader.js -- Environment attaches `loader.cache = {}`
# in _initLoaders. Declaring it here (with the same empty-hash default) gives the
# Environment a clean accessor to reach for instead of poking the object's guts.
has cache => ( is => 'rw', default => sub { {} } );

# loaders opt into async by setting `loader.async = true`; the base is sync.
# Environment reads `loader.async`, so the base answers it (falsey).
sub async { return }

sub _lib { 'Text::Nunjucks::Lib' }

# resolve(from, to) -- path.resolve(path.dirname(from), to), through node's own
# path functions in Lib (ADR 0018): lexical, so '..' collapses on the string
# and the file system is never asked (from 'views/sub/page.njk', '../d.njk' is
# '<cwd>/views/d.njk'), anchored at the working directory only when `from` is
# relative. Environment.resolveTemplate calls it for a relative name, and the
# result is both the loader's cache key and the name getSource receives.
sub resolve {
  my ( $self, $from, $to ) = @_;
  return $self->_lib->node_path_resolve( $self->_lib->node_path_dirname($from), $to );
}

# isRelative(filename) -- a name starting './' or '../'.
sub is_relative {
  my ( $self, $filename ) = @_;
  return ( index( $filename, './' ) == 0 || index( $filename, '../' ) == 0 ) ? 1 : 0;
}

1;

__END__

=head1 NAME

Text::Nunjucks::Loader - base template loader

=head1 DESCRIPTION

A 1:1 port of Nunjucks C<src/loader.js>: the abstract base every loader extends.
It supplies C<resolve> / C<is_relative> for relative template names and, through
the C<Text::Nunjucks::EmitterObj> role, the C<on> / C<emit> event surface the
Environment wires up (C<update> / C<load>). Concrete loaders
(C<FileSystemLoader>, C<PrecompiledLoader>) are not part of this module.

=cut
