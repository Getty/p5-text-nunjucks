package Text::Nunjucks::Runtime::KwArgs;
# ABSTRACT: Marker class for keyword arguments, the __keywords hash (ADR 0009)

our $VERSION = '0.001';

use strict;
use warnings;

# A port addition to runtime.js, at its ADR-designated home beside
# Text::Nunjucks::Runtime (whose ->KwArgs names this class).
#
# Marker class only. makeKeywordArgs blesses a caller hashref into this,
# mirroring JS `obj.__keywords = true` -- but the hash keys stay purely the
# keyword name=>value pairs (no __keywords key polluting them). Not a Moo
# class: its hash IS the data. isKeywordArgs is a blessed/isa check.

1;

__END__

=description

The class the engine blesses a keyword-argument hash into, for the
C<name=value> arguments of a call. Its keys are exactly the keyword names; it
has no methods.

=cut
