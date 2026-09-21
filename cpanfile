requires 'perl', '5.040';

requires 'Moo';
requires 'namespace::autoclean';

on test => sub {
  requires 'JSON::MaybeXS';
  requires 'Path::Tiny';
  requires 'Test::More', '0.96';
};
