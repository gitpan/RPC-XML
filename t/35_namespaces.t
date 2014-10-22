#!/usr/bin/perl

# Test the RPC::XML::Method class

use strict;
use warnings;
use vars qw($obj $obj2 $dir $vol);

use File::Spec;
use Test::More;

use RPC::XML::Procedure;

plan tests => 7;

($vol, $dir, undef) = File::Spec->splitpath(File::Spec->rel2abs($0));
$dir = File::Spec->catpath($vol, $dir, '');

# The organization of the test suites is such that we assume anything that
# runs before the current suite is 100%. Thus, no consistency checks on
# any other classes are done.

$obj = RPC::XML::Method->new(File::Spec->catfile($dir, 'namespace1.xpl'));
# We do an @ISA check again, because we've added the <namespace> tag to the
# mix
isa_ok($obj, 'RPC::XML::Method');
SKIP: {
    skip 'Cannot test without object', 2
        unless (ref($obj) eq 'RPC::XML::Method');

    is($obj->namespace(), 'Test::NS', 'Test namespace() method');
    is($obj->code->(), 'Test::NS', 'Sub closure value of __PACKAGE__');
}

$obj2 = RPC::XML::Method->new(File::Spec->catfile($dir, 'namespace2.xpl'));
isa_ok($obj2, 'RPC::XML::Method');
SKIP: {
    skip 'Cannot test without object', 2
        unless (ref($obj2) eq 'RPC::XML::Method');

    is($obj2->namespace(), 'Test::NS',
       'Test namespace() method (dotted namespace)');
    is($obj2->code->(), 'Test::NS',
       'Sub closure value of __PACKAGE__ (dotted namespace)');
}

$Test::NS::value = 0;
$Test::NS::value++; # Just to suppress the "used only once" warning
$obj = RPC::XML::Method->new(File::Spec->catfile($dir, 'namespace3.xpl'));
SKIP: {
    skip 'Cannot test without object', 1
        unless (ref($obj) eq 'RPC::XML::Method');

    ok($obj->code->(), 'Reading namespace-local value declared outside XPL');
}

exit;
