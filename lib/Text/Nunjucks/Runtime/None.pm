package Text::Nunjucks::Runtime::None;
# ABSTRACT: The JS null sentinel (ADR 0006)

our $VERSION = '0.002';

use strict;
use warnings;

# A port addition to runtime.js, at its ADR-designated home beside
# Text::Nunjucks::Runtime, which hands it out as Text::Nunjucks::Runtime->None.
#
# A single immutable process-wide sentinel standing for JS `null`. Perl
# `undef` is JS `undefined`; a present-but-null value is this object, so the
# null/undefined distinction (is defined / is none / is undefined,
# throwOnUndefined) survives set/macros/filters where an exists-check cannot.
# No stringification/bool overload on purpose: every output/compare/lookup
# path routes None through suppress_value / op_* / member_lookup, so a raw
# None that leaked into bare Perl concat should stay visible, not silently ''.

my $INSTANCE;
sub instance { $INSTANCE //= bless \( my $x ), __PACKAGE__ }

1;

__END__

=description

The one process-wide object standing for JavaScript C<null>, as
C<< Text::Nunjucks::Runtime->None >> returns it. Perl C<undef> is JavaScript
C<undefined>; a value that is present but null is this object.

=cut
