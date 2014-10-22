#!/usr/bin/perl

# http://rt.cpan.org/Ticket/Display.html?id=54183
#
# Test that the RPC::XML::Server class can handle SIGPIPE issues

use strict;
use vars qw($dir $vol $srv $child $port $cli $res);
use subs qw(start_server stop_server find_port);

use Test::More;

require File::Spec;

require RPC::XML::Server;
require RPC::XML::Client;

# This suite doesn't run on Windows, since it's based on *NIX signals
if ($^O eq 'MSWin32' || $^O eq 'cygwin')
{
	plan skip_all => 'Skipping *NIX signals-based test on Windows platform';
	exit;
}

($vol, $dir, undef) = File::Spec->splitpath(File::Spec->rel2abs($0));
$dir = File::Spec->catpath($vol, $dir, '');
require File::Spec->catfile($dir, 'util.pl');

if (($port = find_port) == -1)
{
    plan skip_all => "No usable port found between 9000 and 10000";
}
else
{
    $srv = RPC::XML::Server->new(host => 'localhost', port => $port);
    if (! ref $srv)
    {
        plan skip_all => "Creating server failed: $srv"
    }
    else
    {
        plan tests => 4;
    }
}

$cli = RPC::XML::Client->new("http://localhost:$port");
$srv->add_method({
    name => 'test',
    signature => [ 'string' ],
    code => sub {
        my ($server) = @_;

        sleep 3;

        return 'foo';
    }
});

$child = start_server($srv);

eval {
    local $SIG{ALRM} = sub { die "alarm\n" };
    alarm(1);
    $res = $cli->send_request('test');
    alarm(0); # Shouldn't reach here
};
like($res, qr/alarm/, 'Initial request alarmed-out correctly');

eval {
    local $SIG{ALRM} = sub { die "alarm\n" };
    alarm(6);
    $res = $cli->send_request('test');
    alarm(0); # Shouldn't reach here
};
unlike($res, qr/alarm/, 'Second request did not alarm-out');

ok(ref($res) && $res->value eq 'foo', 'Second request correct value');

eval {
    local $SIG{ALRM} = sub { die "alarm\n" };
    alarm(2);
    $res = $cli->send_request('system.status');
    alarm(0);
};
ok(ref($res) && ref($res->value) eq 'HASH',
   'Good system.status return');

stop_server($child);

exit;
