package Text::Nunjucks::Loader;
# ABSTRACT: 1:1 port of Nunjucks src/loader.js -- the base Loader (resolve/isRelative)

use Moo;
with 'Text::Nunjucks::EmitterObj';
use namespace::autoclean;
use Path::Tiny qw( path );

# src/loader.js: `module.exports = class Loader extends EmitterObj { resolve;
# isRelative }`. EmitterObj -> the on/emit role (ADR 0002). The concrete
# FileSystemLoader / PrecompiledLoader are k19; only this base belongs here.
#
# `cache` is not declared by loader.js -- Environment attaches `loader.cache = {}`
# in _initLoaders. Declaring it here (with the same empty-hash default) gives the
# Environment a clean accessor to reach for instead of poking the object's guts.
has cache => ( is => 'rw', default => sub { {} } );

# loaders opt into async by setting `loader.async = true`; the base is sync.
# Environment reads `loader.async`, so the base answers it (falsey).
sub async { return }

# resolve(from, to) -- JS: path.resolve(path.dirname(from), to). Used only when a
# loader reports isRelative(); no corpus case exercises it (concrete loaders and
# their oracle-checked path behaviour are k19). Ported with Path::Tiny; k19
# validates the exact path.resolve semantics ('..' collapsing, cwd-anchoring).
sub resolve {
  my ( $self, $from, $to ) = @_;
  return path( path($from)->parent, $to )->absolute->stringify;
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
(C<FileSystemLoader>, C<PrecompiledLoader>) are ported separately (k19).

=cut
