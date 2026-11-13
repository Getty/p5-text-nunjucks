package Text::Nunjucks::Nodes;
# ABSTRACT: AST node types for Text::Nunjucks, ported 1:1 from nodes.js

our $VERSION = '0.001';

use strict;
use warnings;
use Carp qw( croak );
use Scalar::Util qw( blessed );
use JSON::MaybeXS ();

# 1:1 port of upstream src/nodes.js. object.js has no Perl counterpart
# (ADR 0002): Moo is the object system and the ~60 concrete AST node types are
# *generated* from their field lists the way upstream's Node.extend(name,
# {fields}) does -- not sixty hand-written class files, and not a second object
# system. The base classes upstream declares with `class` (Node, Value,
# NodeList) plus the two nodes with a custom init (FromImport, CallExtension)
# are written out here as package blocks; every plain `X.extend('Name',
# {fields})` line becomes a row of the @NODE_TYPES table below, in upstream
# declaration order.
#
# nodes.js requires only Obj from object.js, not EmitterObj, so no on/emit role
# is needed here.
#
# Each node answers ->typename (the oracle AST type string), ->fields (arrayref
# of field names in nodes.js order), ->lineno, ->colno and one accessor per
# field. That is exactly the shape t/corpus.t's ast_dump reads.

#### Node -- base class (upstream: class Node extends Obj)

package Text::Nunjucks::Nodes::Node {
  use Moo;
  use namespace::autoclean;
  use Scalar::Util qw( blessed );

  has lineno => ( is => 'ro' );
  has colno  => ( is => 'ro' );

  sub typename { 'Node' }
  sub fields   { [] }

  # Node construction is positional -- new nodes.Symbol(lineno, colno, value) --
  # so BUILDARGS turns the positional call into the hash Moo's constructor
  # wants. The first two args are line/col; the rest map onto the fields in
  # declared order. A field that was not passed stays undef, which encodes to
  # JSON null: upstream's init does the same ("Fields should never be
  # undefined, but null. It makes testing easier to normalize values.").
  sub BUILDARGS {
    my ( $class, @args ) = @_;
    return $class->_field_args(@args);
  }

  sub _field_args {
    my ( $class, $lineno, $colno, @vals ) = @_;
    my $fields = $class->fields;
    my %args = ( lineno => $lineno, colno => $colno );
    for my $i ( 0 .. $#$fields ) {
      $args{ $fields->[$i] } = $vals[$i];
    }
    return \%args;
  }

  # Named once so a subclass can redirect sibling-node construction (house
  # rule: reach for collaborators through the invocant, not a hardcoded name).
  sub _node_class {
    my ( $self, $name ) = @_;
    return 'Text::Nunjucks::Nodes::' . $name;
  }

  sub find_all {
    my ( $self, $type, $results ) = @_;
    $results ||= [];

    if ( $self->isa( $self->_node_class('NodeList') ) ) {
      _traverse_and_check( $_, $type, $results ) for @{ $self->children };
    }
    else {
      _traverse_and_check( $self->$_, $type, $results ) for @{ $self->fields };
    }

    return $results;
  }

  sub iter_fields {
    my ( $self, $func ) = @_;
    $func->( $self->$_, $_ ) for @{ $self->fields };
  }

  # upstream module-level function traverseAndCheck; kept next to find_all, its
  # only caller, since the two are mutually recursive.
  sub _traverse_and_check {
    my ( $obj, $type, $results ) = @_;
    push @$results, $obj if blessed($obj) && $obj->isa($type);
    $obj->find_all( $type, $results )
      if blessed($obj) && $obj->isa('Text::Nunjucks::Nodes::Node');
  }
}

#### Value -- abstract (upstream: class Value extends Node)

package Text::Nunjucks::Nodes::Value {
  use Moo;
  extends 'Text::Nunjucks::Nodes::Node';
  use namespace::autoclean;

  has value => ( is => 'rw' );

  sub typename { 'Value' }
  sub fields   { ['value'] }
}

#### NodeList (upstream: class NodeList extends Node)

package Text::Nunjucks::Nodes::NodeList {
  use Moo;
  extends 'Text::Nunjucks::Nodes::Node';
  use namespace::autoclean;

  has children => ( is => 'rw' );

  sub typename { 'NodeList' }
  sub fields   { ['children'] }

  # init(lineno, colno, nodes) -> super.init(lineno, colno, nodes || [])
  sub BUILDARGS {
    my ( $class, $lineno, $colno, $nodes ) = @_;
    return $class->_field_args( $lineno, $colno, $nodes || [] );
  }

  sub add_child {
    my ( $self, $node ) = @_;
    push @{ $self->children }, $node;
  }
}

#### FromImport -- custom init (upstream: class FromImport extends Node)

package Text::Nunjucks::Nodes::FromImport {
  use Moo;
  extends 'Text::Nunjucks::Nodes::Node';
  use namespace::autoclean;

  has template    => ( is => 'rw' );
  has names       => ( is => 'rw' );
  has withContext => ( is => 'rw' );

  sub typename { 'FromImport' }
  sub fields   { [ 'template', 'names', 'withContext' ] }

  # init(lineno, colno, template, names, withContext)
  #  -> super.init(lineno, colno, template, names || new NodeList(), withContext)
  sub BUILDARGS {
    my ( $class, $lineno, $colno, $template, $names, $withContext ) = @_;
    return $class->_field_args(
      $lineno, $colno,
      $template,
      ( $names || $class->_node_class('NodeList')->new ),
      $withContext
    );
  }
}

#### CallExtension -- custom init (upstream: Node.extend('CallExtension', {init}))

package Text::Nunjucks::Nodes::CallExtension {
  use Moo;
  extends 'Text::Nunjucks::Nodes::Node';
  use namespace::autoclean;
  use Scalar::Util qw( blessed );

  has extName     => ( is => 'rw' );
  has prop        => ( is => 'rw' );
  has args        => ( is => 'rw' );
  has contentArgs => ( is => 'rw' );
  has autoescape  => ( is => 'rw' );   # carried from the extension; not a field

  sub typename { 'CallExtension' }
  sub fields   { [ 'extName', 'prop', 'args', 'contentArgs' ] }

  # init(ext, prop, args, contentArgs): note -- no lineno/colno. Upstream calls
  # this.parent() first, which leaves lineno/colno undefined and then overwrites
  # the four fields below, so the observable end state is exactly this hash.
  #   extName = ext.__name || ext ; autoescape = ext.autoescape
  # How an extension is represented in Perl is not yet decided; extName and
  # autoescape are read as an object method or a hash key, else the value passes
  # through (mirroring `ext.__name || ext` for a bare string ext).
  sub BUILDARGS {
    my ( $class, $ext, $prop, $args, $contentArgs ) = @_;
    return {
      lineno      => undef,
      colno       => undef,
      extName     => ( _ext_attr( $ext, '__name' ) || $ext ),
      prop        => $prop,
      args        => ( $args || $class->_node_class('NodeList')->new ),
      contentArgs => ( $contentArgs || [] ),
      autoescape  => _ext_attr( $ext, 'autoescape' ),
    };
  }

  sub _ext_attr {
    my ( $ext, $prop ) = @_;
    return undef unless defined $ext && ref $ext;
    return ( $ext->can($prop) ? $ext->$prop : undef ) if blessed $ext;
    return $ext->{$prop} if ref $ext eq 'HASH';
    return undef;
  }
}

#### Concrete node types -- generated (upstream: the const X = Y.extend(...) lines)

# One row per upstream `const X = Parent.extend('Name'[, {fields}])`, in
# nodes.js declaration order. A row is [ Name, Parent, \@fields ]; the fields
# arrayref is present only where upstream passes {fields}, exactly as upstream
# only overrides fields when they change (otherwise they inherit). The two
# custom-init nodes at their upstream positions -- FromImport (between Import
# and FunCall) and CallExtension (before CallExtensionAsync) -- are written out
# as package blocks above and marked here so the table maps to nodes.js.
my @NODE_TYPES = (
  [ 'Root',           'NodeList' ],
  [ 'Literal',        'Value' ],
  [ 'Symbol',         'Value' ],
  [ 'Group',          'NodeList' ],
  [ 'Array',          'NodeList' ],
  [ 'Pair',           'Node',        [ 'key', 'value' ] ],
  [ 'Dict',           'NodeList' ],
  [ 'LookupVal',      'Node',        [ 'target', 'val' ] ],
  [ 'If',             'Node',        [ 'cond', 'body', 'else_' ] ],
  [ 'IfAsync',        'If' ],
  [ 'InlineIf',       'Node',        [ 'cond', 'body', 'else_' ] ],
  [ 'For',            'Node',        [ 'arr', 'name', 'body', 'else_' ] ],
  [ 'AsyncEach',      'For' ],
  [ 'AsyncAll',       'For' ],
  [ 'Macro',          'Node',        [ 'name', 'args', 'body' ] ],
  [ 'Caller',         'Macro' ],
  [ 'Import',         'Node',        [ 'template', 'target', 'withContext' ] ],
  # FromImport (Node, custom init) -- written out above
  [ 'FunCall',        'Node',        [ 'name', 'args' ] ],
  [ 'Filter',         'FunCall' ],
  [ 'FilterAsync',    'Filter',      [ 'name', 'args', 'symbol' ] ],
  [ 'KeywordArgs',    'Dict' ],
  [ 'Block',          'Node',        [ 'name', 'body' ] ],
  [ 'Super',          'Node',        [ 'blockName', 'symbol' ] ],
  [ 'TemplateRef',    'Node',        [ 'template' ] ],
  [ 'Extends',        'TemplateRef' ],
  [ 'Include',        'Node',        [ 'template', 'ignoreMissing' ] ],
  [ 'Set',            'Node',        [ 'targets', 'value' ] ],
  [ 'Switch',         'Node',        [ 'expr', 'cases', 'default' ] ],
  [ 'Case',           'Node',        [ 'cond', 'body' ] ],
  [ 'Output',         'NodeList' ],
  [ 'Capture',        'Node',        [ 'body' ] ],
  [ 'TemplateData',   'Literal' ],
  [ 'UnaryOp',        'Node',        [ 'target' ] ],
  [ 'BinOp',          'Node',        [ 'left', 'right' ] ],
  [ 'In',             'BinOp' ],
  [ 'Is',             'BinOp' ],
  [ 'Or',             'BinOp' ],
  [ 'And',            'BinOp' ],
  [ 'Not',            'UnaryOp' ],
  [ 'Add',            'BinOp' ],
  [ 'Concat',         'BinOp' ],
  [ 'Sub',            'BinOp' ],
  [ 'Mul',            'BinOp' ],
  [ 'Div',            'BinOp' ],
  [ 'FloorDiv',       'BinOp' ],
  [ 'Mod',            'BinOp' ],
  [ 'Pow',            'BinOp' ],
  [ 'Neg',            'UnaryOp' ],
  [ 'Pos',            'UnaryOp' ],
  [ 'Compare',        'Node',        [ 'expr', 'ops' ] ],
  [ 'CompareOperand', 'Node',        [ 'expr', 'type' ] ],
  # CallExtension (Node, custom init) -- written out above
  [ 'CallExtensionAsync', 'CallExtension' ],
);

# Build one Moo class per row: mirror upstream's extendClass -- subclass the
# parent, give it its own typename, and (only where fields change) declare the
# new field accessors and its own fields() list. Everything else -- inherited
# fields, accessors and the positional BUILDARGS -- comes through normal
# inheritance, the way JS prototype chaining carries it upstream. The class is
# built with a small string eval so use Moo/extends/has run in the target
# package (each eval is its own scope, so namespace::autoclean is safe here).
sub _extend {
  my ( $name, $parent, $fields ) = @_;
  my $pkg    = __PACKAGE__ . '::' . $name;
  my $parpkg = __PACKAGE__ . '::' . $parent;

  my @new_accessors;
  if ($fields) {
    my %inherited = map { $_ => 1 } @{ $parpkg->fields };
    @new_accessors = grep { !$inherited{$_} } @$fields;
  }

  my $src = "package $pkg;\n"
    . "use Moo;\n"
    . "extends '$parpkg';\n"
    . "use namespace::autoclean;\n";
  $src .= "has '$_' => ( is => 'rw' );\n" for @new_accessors;
  $src .= "1;\n";
  eval $src or croak __PACKAGE__ . "->_extend: could not build $name: $@";

  # typename is set fresh on every extend upstream (never inherited).
  { no strict 'refs'; *{"${pkg}::typename"} = sub { $name }; }

  # fields() is installed only where this class changes the list; otherwise it
  # inherits the parent's, exactly as upstream leaves {fields} out to inherit.
  if ($fields) {
    my @f = @$fields;
    no strict 'refs';
    *{"${pkg}::fields"} = sub { [@f] };
  }
}

_extend(@$_) for @NODE_TYPES;

# Set carries a non-field `body`. Upstream declares Set with fields
# {targets, value}, and the parser attaches a block-set's Capture to node.body
# dynamically (parser.js parseSet), which the compiler reads back
# (compiler.js compileSet). It is not a field(), so it never appears in the AST
# dump -- exactly the CallExtension.autoescape pattern above: a real accessor
# that lives outside the field list. Added here rather than in the table so the
# @NODE_TYPES rows keep mapping 1:1 to nodes.js's extend() calls.
{
  package Text::Nunjucks::Nodes::Set;
  use Moo;
  has body => ( is => 'rw' );
}

#### printNodes -- AST pretty-printer (upstream: print / printNodes)

my $JSON = JSON::MaybeXS->new( canonical => 1, convert_blessed => 1 )->pretty(1);

# upstream `print`. "This is hacky, but this is just a debugging function
# anyway." A non-empty line ("0" counts, unlike Perl truthiness) is prefixed
# with `indent` spaces; the last line gets no trailing newline. NOTE: debug
# helper only, not byte-asserted anywhere -- the property JSON's whitespace and
# key order differ from JS's JSON.stringify (Perl hashes are unordered).
sub _print {
  my ( $str, $indent, $inline ) = @_;
  $indent = 0 unless defined $indent;
  my @lines = split /\n/, $str, -1;
  for my $i ( 0 .. $#lines ) {
    my $line = $lines[$i];
    print STDOUT ( ' ' x $indent )
      if length($line) && ( ( $inline && $i > 0 ) || !$inline );
    print STDOUT $line . ( $i == $#lines ? '' : "\n" );
  }
}

# Print the AST in a nicely formatted tree format for debuggin
sub print_nodes {
  my ( $node, $indent ) = @_;
  $indent = $indent || 0;

  _print( $node->typename . ': ', $indent );

  if ( $node->isa('Text::Nunjucks::Nodes::NodeList') ) {
    _print("\n");
    print_nodes( $_, $indent + 2 ) for @{ $node->children };
  }
  elsif ( $node->isa('Text::Nunjucks::Nodes::CallExtension') ) {
    _print( $node->extName . '.' . $node->prop . "\n" );

    print_nodes( $node->args, $indent + 2 ) if $node->args;

    if ( $node->contentArgs ) {
      print_nodes( $_, $indent + 2 ) for @{ $node->contentArgs };
    }
  }
  else {
    my @nodes;
    my $props;

    $node->iter_fields( sub {
      my ( $val, $field_name ) = @_;
      if ( blessed($val) && $val->isa('Text::Nunjucks::Nodes::Node') ) {
        push @nodes, [ $field_name, $val ];
      }
      else {
        $props ||= {};
        $props->{$field_name} = $val;
      }
    } );

    if ($props) {
      _print( $JSON->encode($props) . "\n", undef, 1 );
    }
    else {
      _print("\n");
    }

    for my $pair (@nodes) {
      my ( $field_name, $n ) = @$pair;
      _print( '[' . $field_name . '] =>', $indent + 2 );
      print_nodes( $n, $indent + 4 );
    }
  }
}

1;

__END__

=head1 DESCRIPTION

Engine-internal: this module is a stage of the template pipeline, used by
L<Text::Nunjucks::Environment>, and not an interface for applications.

A 1:1 port of Nunjucks C<src/nodes.js>. Defines the base node classes
(C<Node>, C<Value>, C<NodeList>) and the two nodes with a custom constructor
(C<FromImport>, C<CallExtension>) explicitly, and generates the remaining
concrete node types from their field lists, mirroring upstream's
C<Node.extend(name, { fields })>.

Every node lives in the C<Text::Nunjucks::Nodes::> namespace (e.g.
C<Text::Nunjucks::Nodes::Symbol>) and is constructed positionally:

    Text::Nunjucks::Nodes::Symbol->new( $lineno, $colno, $value );

Each node answers C<typename>, C<fields> (an arrayref of field names in
declared order), C<lineno>, C<colno>, and one accessor per field.

=cut
