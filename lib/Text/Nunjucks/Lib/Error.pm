package Text::Nunjucks::Lib::Error;
# ABSTRACT: Port representation of a JS built-in Error / TypeError (name + message)

use Moo;
use namespace::autoclean;

# src/lib.js reaches for the JS globals `new Error(...)` (inOperator) and
# `new TypeError(...)` (groupBy). Perl has no universal Error base, so the port
# models a thrown JS error as a small object carrying { name, message } -- the
# two fields _prettifyError reads back ("${cause.name}: ${cause.message}") and
# the corpus harness reads (->name / ->message). `name` defaults to 'Error';
# callers that want a different JS error type pass name => 'TypeError'.
#
# NOTE (open mapping): how JS built-in error types map to Perl is not yet
# settled by an ADR -- see the k9 report. This class is the single, minimal
# place that representation is encapsulated.

has message => ( is => 'ro' );
has name    => ( is => 'ro', default => sub { 'Error' } );

around BUILDARGS => sub {
  my ( $orig, $class, @args ) = @_;
  return $class->$orig(@args) if @args == 1 && ref $args[0] eq 'HASH';
  my ( $message, %opts ) = @args;
  return $class->$orig( message => $message, %opts );
};

1;
