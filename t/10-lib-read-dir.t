#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Path::Tiny ();
use Scalar::Util qw( blessed refaddr );
use Symbol ();

# node's fs.readFileSync of a directory opens it and fails in the read:
# "EISDIR: illegal operation on a directory, read" (the oracle, on Linux;
# t/corpus/render-loaders.json has it through FileSystemLoader). Linux, macOS
# and FreeBSD fail read(2) on a directory with EISDIR; NetBSD, DragonFly and
# GNU/Hurd hand out the directory's raw entries instead, which then rendered
# as template source. The read below stands in for theirs: for a directory
# handle it returns entry bytes once, then end of file. CORE::GLOBAL::read
# reaches every read compiled after it, so it is set up before the modules
# under test load, and lives in a file of its own.

my $DIRENTS = "\x0c\x00\x04\x01.\x00\x00\x00\x0c\x00\x04\x02..\x00\x00";
my %served;

BEGIN {
  no warnings 'once';
  *CORE::GLOBAL::read = sub (*\$$;$) {
    my ( $fh, $buf, $len, $off ) = @_;
    $fh = Symbol::qualify_to_ref( $fh, scalar caller ) unless ref $fh;
    return CORE::read( $fh, $$buf, $len, $off // 0 ) unless -d $fh;
    if ( delete $served{ refaddr $fh } ) {
      return 0;
    }
    $served{ refaddr $fh } = 1;
    $$buf = '' unless defined $$buf;
    substr( $$buf, $off // 0 ) = $DIRENTS;
    return length $DIRENTS;
  };
}

use Text::Nunjucks::Lib;
use Text::Nunjucks::Environment;
use Text::Nunjucks::Loader::FileSystem;

my $L   = 'Text::Nunjucks::Lib';
my $dir = Path::Tiny->tempdir;
$dir->child('sub')->mkpath;
$dir->child('page.njk')->spew_raw('[{% include "./sub" %}]');

my $EISDIR = 'EISDIR: illegal operation on a directory, read';

subtest 'the stand-in read hands out a directory' => sub {
  open( my $fh, '<:raw', "$dir" ) or plan skip_all => "a directory does not open here: $!";
  my $got = '';
  my $n   = read( $fh, $got, 65536 );
  close $fh;
  is( $n,   length $DIRENTS, 'read returns the entries' );
  is( $got, $DIRENTS,        '... their bytes' );
};

subtest "readFileSync(dir, 'utf-8') throws node's EISDIR wherever read(2) succeeds" => sub {
  my $e = do { local $@; eval { $L->node_fs_read_file_sync_utf8("$dir"); 1 } ? undef : $@ };
  ok( blessed($e) && $e->isa('Text::Nunjucks::Lib::Error'), 'a directory throws an Error' );
  is( blessed($e) && $e->name,    'Error', '... named Error' );
  is( blessed($e) && $e->message, $EISDIR, "... with node's message" );
  is( $L->node_fs_read_file_sync_utf8( $dir->child('page.njk') . '' ), '[{% include "./sub" %}]', 'a file still reads' );
};

# As in t/corpus.t's render mode (the cases there): an error is what the
# render throws -- a loader's, for the template itself -- or hands its callback.
sub render_result {
  my ( $env, $name ) = @_;
  my ( $err, $res );
  local $@;
  eval { $env->render( $name, {}, sub { ( $err, $res ) = @_ } ); 1 } or $err = $@;
  return ( $err, $res );
}

subtest 'FileSystemLoader: a directory name and an include of a directory throw EISDIR' => sub {
  my $env = Text::Nunjucks::Environment->new( Text::Nunjucks::Loader::FileSystem->new("$dir") );
  my ( $err, $res ) = render_result( $env, 'sub' );
  is( blessed($err) && $err->message, $EISDIR, 'render of a directory name' );
  is( $res, undef, '... and no output' );

  ( $err, $res ) = render_result( $env, 'page.njk' );
  like( blessed($err) && $err->message, qr/\n  Error: \Q$EISDIR\E\z/, 'an include of a directory' );
  is( $res, undef, '... and no output' );
};

done_testing;
