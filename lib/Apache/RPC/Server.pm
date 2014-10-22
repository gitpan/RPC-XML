###############################################################################
#
# This file copyright (c) 2001 by Randy J. Ray <rjray@blackperl.com>,
# all rights reserved
#
# Copying and distribution are permitted under the terms of the Artistic
# License as distributed with Perl versions 5.005 and later. See
# http://language.perl.com/misc/Artistic.html
#
###############################################################################
#
#   $Id: Server.pm,v 1.5 2001/06/13 05:02:45 rjray Exp $
#
#   Description:    This package implements a RPC server as an Apache/mod_perl
#                   content handler. It uses the RPC::XML::Server package to
#                   handle request decoding and response encoding.
#
#   Functions:      handler
#                   new
#
#   Libraries:      RPC::XML::Server
#
#   Global Consts:  $VERSION
#
###############################################################################

package Apache::RPC::Server;

use 5.005;
use strict;

use File::Spec;

use Apache;
use Apache::File; # For ease-of-use methods like set_last_modified
use Apache::Constants ':common';

use RPC::XML::Server;
@Apache::RPC::Server::ISA = qw(RPC::XML::Server);

BEGIN
{
    $Apache::RPC::Server::INSTALL_DIR = (File::Spec->splitpath(__FILE__))[1];
    %Apache::RPC::Server::SERVER_TABLE = ();
}

$Apache::RPC::Server::VERSION = do { my @r=(q$Revision: 1.5 $=~/\d+/g); sprintf "%d."."%02d"x$#r,@r };

1;

sub version { $Apache::RPC::Server::VERSION }

sub debug
{
    my $self = shift;
    my $fmt  = shift;

    my $debug = ref($self) ? $self->SUPER::debug() : 1;

    $fmt && $debug &&
        Apache::log_error(sprintf("%p ($$): $fmt",
                                  (ref $self) ? $self : 0, @_));

    $debug;
}

###############################################################################
#
#   Sub Name:       handler
#
#   Description:    This is the default routine that Apache will look for
#                   when we set this class up as a content handler.
#
#   Arguments:      NAME      IN/OUT  TYPE      DESCRIPTION
#                   $class    in      scalar    Static name of the class we're
#                                                 invoked in
#                   $r        in      ref       Blessed Apache::Request object
#
#   Globals:        $DEF_OBJ
#
#   Environment:    None.
#
#   Returns:        Response code
#
###############################################################################
sub handler ($$)
{
    my $class = shift;
    my $r = shift;

    my ($self, $srv, $content, $resp, $respxml);

    $srv = (ref $class) ? $class : $class->get_server($r);
    unless (ref $srv)
    {
        $r->log_error(__PACKAGE__ . ': PANIC! ' . $srv);
        return SERVER_ERROR;
    }

    # Set the relevant headers
    my $hdrs = $srv->response->headers;
    for (keys %$hdrs) { $r->header_out($_ => $hdrs->{$_}) }
    # We're essentially done if this was a HEAD request
    if ($r->header_only)
    {
        # These headers are either only sent for HEAD requests or are different
        # enough to move here from the above block
        $r->set_last_modified($srv->started);
        $r->send_http_header;
    }
    elsif ($r->method eq 'POST')
    {
        # Step 1: Do we have the correct content-type?
        return DECLINED unless ($r->header_in('Content-Type') eq 'text/xml');
        $r->read($content, $r->header_in('Content-Length'));

        # Step 2: Process the request and encode the outgoing response
        # Dispatch will always return a RPC::XML::response
        $resp = $srv->dispatch(\$content);
        $respxml = $resp->as_string;

        # Step 3: Form up and send the headers and body of the response
        $r->content_type('text/xml');
        $r->set_content_length(length $respxml);
        $r->no_cache(1);
        $r->send_http_header;
        $r->print(\$respxml);
    }
    else
    {
        # Flag this as an error, since we don't permit the other methods
        return DECLINED;
    }

    return OK;
}

###############################################################################
#
#   Sub Name:       init_handler
#
#   Description:    Provide a handler for the PerlChildInitHandler phase that
#                   walks through the table of server objects and updates the
#                   child_started time on each.
#
#   Arguments:      NAME      IN/OUT  TYPE      DESCRIPTION
#                   $class    in      scalar    Calling class (this is a method
#                                                 handler)
#                   $r        in      ref       Apache reference object
#
#   Globals:        %SERVER_TABLE
#
#   Environment:    None.
#
#   Returns:        1
#
###############################################################################
sub init_handler ($$)
{
    my ($class, $r) = @_;

    $_->child_started(1) for (values %Apache::RPC::Server::SERVER_TABLE);

    1;
}

###############################################################################
#
#   Sub Name:       new
#
#   Description:    Create a new server object, which is blessed into this
#                   class and thus inherits most of the important bits from
#                   RPC::XML::Server.
#
#   Arguments:      NAME      IN/OUT  TYPE      DESCRIPTION
#                   $class    in      scalar    String or ref to ID the class
#                   @argz     in      list      Type and relevance of args is
#                                                 variable. See text.
#
#   Globals:        $INSTALL_DIR
#
#   Environment:    None.
#
#   Returns:        Success:    ref to new object
#                   Failure:    error string
#
###############################################################################
sub new
{
    my $class = shift;
    my @argz  = @_;

    my ($R, $servid, $prefix, $self, @dirs, @files, $ret, $no_def, $debug,
        $do_auto, $do_mtime);

    ($R, $servid, $prefix) = splice(@argz, 0, 3);
    push(@argz, path => $R->location) unless (grep(/^path$/, @argz));

    # Is debugging requested?
    $debug = $R->dir_config("${prefix}RpcDebugLevel") || 0;
    # Check for disabling of auto-loading or mtime-checking
    $do_auto  = $R->dir_config("${prefix}RpcAutoMethods");
    $do_mtime = $R->dir_config("${prefix}RpcAutoUpdates");
    foreach ($do_auto, $do_mtime) { $_ = (/yes/i) ? 1 : 0 }

    # Create the object, ensuring that the defaults are not yet loaded:
    $self = $class->SUPER::new(no_default => 1, debug => $debug, no_http => 1,
                               host => $R->hostname,
                               port => $R->get_server_port,
                               auto_methods => $do_auto,
                               auto_updates => $do_mtime,
                               xpl_path =>
                               [ $Apache::RPC::Server::INSTALL_DIR ],
                               @argz);
    return $self unless (ref $self); # Non-ref means an error message
    $self->started('set');

    # Check to see if we should suppress the default methods
    $no_def = $R->dir_config("${prefix}RpcDefMethods");
    $no_def = ($no_def =~ /no/i) ? 1 : 0;
    unless ($no_def)
    {
        $self->add_default_methods(-except => 'status.xpl');
        # This should find the Apache version of system.status instead
        $self->add_method('status.xpl');
    }

    # Determine what methods we are configuring for this server instance
    @dirs    = split(/:/, $R->dir_config("${prefix}RpcMethodDir"));
    @files   = split(/:/, $R->dir_config("${prefix}RpcMethod"));
    # Load the directories first, then the individual files. This allows the
    # files to potentially override entries in the directories.
    for (@dirs)
    {
        $ret = $self->add_methods_in_dir($_);
        return $ret unless ref $ret;
    }
    for (@files)
    {
        $ret = $self->add_method($_);
        return $ret unless ref $ret;
    }
    $ret = $self->xpl_path;
    unshift(@$ret, @dirs);
    $self->xpl_path($ret);

    $Apache::RPC::Server::SERVER_TABLE{$servid} = $self;
    $self;
}

# Accessor similar to started() that has a time localized to this child process
sub child_started
{
    my $self = shift;
    my $set  = shift || 0;

    my $old = $self->{__child_started} || $self->started || 0;
    $self->{__child_started} = time if $set;

    $old;
}

###############################################################################
#
#   Sub Name:       get_server
#
#   Description:    Retrieve the server object for the specified fully-qual'd
#                   URL passed in as arg #2. Note that this isn't a class
#                   method-- it's only called by handler() and the first arg
#                   is the Apache object reference.
#
#   Arguments:      NAME      IN/OUT  TYPE      DESCRIPTION
#                   $self     in      sc/ref    Object ref or class name
#                   $r        in      ref       Apache interface object ref
#
#   Globals:        %SERVER_TABLE
#
#   Environment:    None.
#
#   Returns:        object ref, either specific or the default object. Sends a
#                   text string if new() fails
#
###############################################################################
sub get_server
{
    my $self     = shift;
    my $r        = shift;

    my $prefix = $r->dir_config('RPCOptPrefix') || '';
    my $servid = $r->dir_config("${prefix}RpcServer") || '<default>';

    $Apache::RPC::Server::SERVER_TABLE{$servid} ||
        $self->new($r, $servid, $prefix,
                   # These are parameters that bubble up to the SUPER::new()
                   xpl_path => [ $Apache::RPC::Server::INSTALL_DIR ],
                   no_http  => 1, # We, um, have that covered
                   path     => $r->location);
}

__END__

=pod

=head1 NAME

Apache::RPC::Server - A subclass of RPC::XML::Server class tuned for mod_perl

=head1 SYNOPSIS

    # In httpd.conf:
    PerlSetVar RpcMethodDir /var/www/rpc:/usr/lib/perl5/RPC-shared
    PerlChildInitHandler Apache::RPC::Server->init_handler
    ...
    <Location /RPC>
        SetHandler perl-script
        PerlHandler Apache::RPC::Server
    </Location>
    </Location /RPC-limited>
        SetHandler perl-script
        PerlHandler Apache::RPC::Server
        PerlSetVar RPCOptPrefix RpcLimit
        PerlSetVar RpcLimitRpcServer Limited
        PerlSetVar RpcLimitRpcMethodDir /usr/lib/perl5/RPC-shared
    </Location>

    # In the start-up Perl file:
    use Apache::RPC::Server;

=head1 DESCRIPTION

The B<Apache::RPC::Server> module is a subclassing of B<RPC::XML::Server> that
is tuned and designed for use within Apache with mod_perl.

Provided are phase-handlers for the general request-processing phase
(C<PerlHandler>) and the child-process initialization phase
(C<PerlChildInitHandler>). The module should be loaded either by inclusion in a
server start-up Perl script or by directives in the server configuration file
(generally F<httpd.con>). One loaded, the configuration file may assign the
module to handle one or more given locations with the general set of
C<E<lt>LocationE<gt>> directives and familiar options. Additional configuration
settings specific to this module are detailed below.

Generally, externally-available methods are provided as files in the XML
dialect explained in L<RPC::XML::Server>. A subclass derived from this class
may of course use the methods provided by this class and its parent class for
adding and manipulating the method table.

=head1 USAGE

This module is designed to be dropped in with little (if any) modification.
The methods that the server publishes are provided by a combination of the
installation files and Apache configuration values. Details on remote method
syntax and semantics is covered in L<RPC::XML::Server>.

=head2 Methods

In addition to inheriting all the methods from B<RPC::XML::Server>, the
following methods are either added or overloaded by B<Apache::RPC::Server>:

=over 4

=item handler

This is the default content-handler routine that B<mod_perl> expects when the
module is defined as managing the specified location. This is provided as a
I<method handler>, meaning that the first argument is either an object
reference or a static string with the class name. This allows for other
packages to easily subclass B<Apache::RPC::Server>.

This routine takes care of examining the incoming request, choosing an
appropriate server object to actually process the request, and returning the
results of the remote method call to the client.

=item init_handler

This is another Apache-level handler, this one designed for installation as a
C<PerlChildInitHandler>. At present, its only function is to iterate over all
server object currently in the internal tables and invoke the C<child_started>
method (detailed below) on each. Setting this handler assures that each child
has a correct impression of when it started as opposed to the start time of the
server itself.

Note that this is only applied to those servers known to the master Apache
process. In most cases, this will only be the default server object as
described above. That is because of the delayed-loading nature of all servers
beyond the default, which are likely only in child-specific memory. There are
some configuration options described in the next section that can affect and
alter this.

=item new

This is the class constructor. It calls the superclass C<new> method, then
performs some additional steps. These include installing the default methods
(which includes an Apache-specific version of C<system.status>), adding the
installation directory of this module to the method search path, and adding any
directories or explicitly-requested methods to the server object.

This version of C<new> expects the argument list to follow one of two patterns:
it is either a single token "C<set-default>", which creates and initializes the
default server, or it has the following elements (in order):

        Apache class instance (reference)
        Server ID string of the server being created
        Prefix (if any) to be applied to the configuration values fetched
        (All remaining arguments are passed unchanged to C<SUPER::new()>)

The server identification string and prefix concepts are explained in more
detail in the next section.

=item child_started([BOOLEAN])

This method is very similar to the C<started> method provided by
B<RPC::XML::Server>. When called with no argument or an argument that evaluates
to a false value, it returns the UNIX-style time value of when this child
process was started. Due to the child-management model of Apache, this may very
well be different from the value returned by C<started> itself. If given an
argument that evaluates as true, the current system time is set as the new
child-start time.

If the server has not been configured to set this at child initialization, then
the main C<started> value is returned. The name is different so that a child
may specify both server-start and child-start times with clear distinction.

=item version

This method behaves exactly like the B<RPC::XML::Server> method, save that the
version string returned is (surprisingly enough) for this module instead.

=back

=head2 Apache configuration semantics

In addition to the known directives such as C<PerlHandler> and
C<PerlChildInitHandler>, configuration of this system is controlled through a
variety of settings that are manipulated with the C<PerlSetVar> and
C<PerlAddVar> directives. These variables are:

=over 4

=item RPCOptPrefix [STRING]

Sets a prefix string to be applied to all of the following names before trying
to read their values. Useful for setting within a C<E<lt>LocationE<gt>> block
to ensure that no settings from a higher point in the hierarchy influence the
server being defined.

=item RpcServer [STRING]

Specify the name of the server to use for this location. If not passed, then
the default server is used. This server may also be explicitly requested by the
name "C<C<E<lt>defaultE<gt>>>". If more than one server are going to be created
within the same Apache environment, this setting should always be used outside
the default area so that the default server is not loaded down with extra
method definitions. If a sub-location changes the default server, those changes
will be felt by any location that uses that server.

Different locations may share the same server by specifying the name with this
variable. This is useful for managing varied access schemes, traffic analysis,
etc.

=item RpcServerDir [DIRECTORY]

This variable specifies directories to be scanned for method C<*.xpl>
files. To specify more than one directory, separate them with "C<:>" just as
with any other directory-path expression. All directories are kept (in the
order specified) as the search path for future loading of methods.

=item RpcServerMethod [FILENAME]

This is akin to the directory-specification option above, but only provides a
single method at a time. It may also have multiple values separated by
colons. The method is loaded into the server table. If the name is not an
absolute pathname, then it is searched for in the directories that currently
comprise the path. The directories above, however, have not been added to the
search path yet. This is because these directives are processed immediately
after the directory specifications, and thus do not need to be searched. This
directive is designed to allow selective overriding of methods in the
previously-specified directories.

=item RpcDefMethods [YES|NO]

If specified and set to "no" (case-insensitive), suppresses the loading of the
system default methods that are provided with this package. The absence of this
setting is interpreted as a "yes", so explicitly specifying such is not needed.

=item RpcAutoMethods [YES|NO]

If specified and set to "yes", enables the automatic searching for a requested
remote method that is unknown to the server object handling the request. If
set to "no" (or not set at all), then a request for an unknown function causes
the object instance to report an error. If the routine is still not found, the
error is reported. Enabling this is a security risk, and should only be
permitted by a server administrator with fully informed acknowledgement and
consent.

=item RpcNoAutoUpdate [YES|NO]

(Not yet implemented) If specified and set to "yes", enables the checking of
the modification time of the file from which a method was originally
loaded. If the file has changed, the method is re-loaded before execution is
handed off. As with the auto-loading of methods, this represents a security
risk, and should only be permitted by a server administrator with fully
informed acknowledgement and consent.

=item RpcDebugLevel [NUMBER]

Enable debugging by providing a numerical value that will
be used as the debug setting by the parent class, B<RPC::XML::Server>.

=back

=head2 Specifying methods to the server(s)

Methods are provided to an B<Apache::RPC::Server> object in three ways:

=over 4

=item Default methods

Unless suppressed by a C<RpcDefMethods> option, the methods shipped with this
package are loaded into the table. The B<Apache::RPC::Server> objects get a
slightly different version of C<system.status> than the parent class does.

=item Configured directories

All method files (those ending in a suffix of C<*.xpl>) in the directories
specified in the relevant C<RpcMethodDir> settings are read next. These
directories are also (after the next step) added to the search path the object
uses.

=item By specific inclusion

Any methods specified directly by use of C<RpcMethod> settings are loaded
last. This allows for them to override methods that may have been loaded from
the system defaults or the specified directories.

=back

If a request is made for an unknown method, the object will first attempt to
find it by searching the path of directories that were given in the
configuration as well as those that are part of the system (installation-level
directories). If it is still not found, then an error is reported back to the
requestor. By using this technique, it is possible to add methods to a running
server without restarting it. It is a potential security hole, however, and it
is for that reason that the previously-documented C<RpcNoNewMethods> setting is
provided.

=head1 DIAGNOSTICS

All methods return some type of reference on success, or an error string on
failure. Non-reference return values should always be interpreted as errors
unless otherwise noted.

Where appropriate, the C<log_error> method from the B<Apache> package
is called to note internal errors.

=head1 CAVEATS

This is a reference implementation in which clarity of process and readability
of the code took precedence over general efficiency. Much, if not all, of this
can be written more compactly and/or efficiently.

=head1 CREDITS

The B<XML-RPC> standard is Copyright (c) 1998-2001, UserLand Software, Inc.
See <http://www.xmlrpc.com> for more information about the B<XML-RPC>
specification.

=head1 LICENSE

This module is licensed under the terms of the Artistic License that covers
Perl itself. See <http://language.perl.com/misc/Artistic.html> for the
license itself.

=head1 SEE ALSO

L<RPC::XML::Server>, L<RPC::XML>

=head1 AUTHOR

Randy J. Ray <rjray@blackperl.com>
