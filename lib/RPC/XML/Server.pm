###############################################################################
#
# This file copyright (c) 2001 by Randy J. Ray <rjray@blackperl.com>,
# all rights reserved
#
# Copying and distribution are permitted under the terms of the Artistic
# License as distributed with Perl versions 5.002 and later. See
# http://language.perl.com/misc/Artistic.html
#
###############################################################################
#
#   $Id: Server.pm,v 1.18 2001/10/08 00:48:04 rjray Exp $
#
#   Description:    This class implements an RPC::XML server, using the core
#                   XML::RPC transaction code. The server may be created with
#                   or without an HTTP::Daemon object instance to answer the
#                   requests.
#
#   Functions:      new
#                   version
#                   url
#                   product_tokens
#                   started
#                   path
#                   host
#                   port
#                   requests
#                   response
#                   xpl_path
#                   add_method
#                   method_from_file
#                   get_method
#                   server_loop
#                   post_configure_hook
#                   pre_loop_hook
#                   process_request
#                   dispatch
#                   call
#                   add_default_methods
#                   add_methods_in_dir
#
#   Libraries:      AutoLoader
#                   HTTP::Daemon
#                   HTTP::Status
#                   RPC::XML
#                   RPC::XML::Parser
#                   RPC::XML::Method
#
#   Global Consts:  $VERSION
#                   $INSTALL_DIR
#
###############################################################################

package RPC::XML::Server;

use 5.005;
use strict;
use vars qw($VERSION @ISA $INSTANCE $INSTALL_DIR @XPL_PATH);

use Carp 'carp';
use AutoLoader 'AUTOLOAD';
use File::Spec;

BEGIN {
    $INSTALL_DIR = (File::Spec->splitpath(__FILE__))[1];
    @XPL_PATH = ($INSTALL_DIR, File::Spec->curdir);
}

require HTTP::Daemon;
require HTTP::Response;
use HTTP::Status; # The only one we import from
require URI;

require RPC::XML;
require RPC::XML::Parser;
require RPC::XML::Method;

$VERSION = do { my @r=(q$Revision: 1.18 $=~/\d+/g); sprintf "%d."."%02d"x$#r,@r };

1;

###############################################################################
#
#   Sub Name:       new
#
#   Description:    Create a new RPC::XML::Server object. This entails getting
#                   a HTTP::Daemon object, saving several internal values, and
#                   other operations.
#
#   Arguments:      NAME      IN/OUT  TYPE      DESCRIPTION
#                   $class    in      scalar    Ref or string for the class
#                   %args     in      hash      Additional arguments
#
#   Globals:        None.
#
#   Environment:    None.
#
#   Returns:        Success:    object reference
#                   Failure:    error string
#
###############################################################################
sub new
{
    my $class = shift;
    my %args = @_;

    my ($self, $http, $resp, $host, $port, $queue, $path, $URI, $srv_name,
        $srv_version);

    $class = ref($class) || $class;
    $self = bless {}, $class;

    $srv_version = $args{server_version} || $self->version;
    $srv_name    = $args{server_name}    || $class;
    $self->{__version} = "$srv_name/$srv_version";

    unless ($args{no_http})
    {
        $host = $args{host}   || '';
        $port = $args{port}   || '';
        $queue = $args{queue} || 5;
        $http = HTTP::Daemon->new(($host ? (LocalHost => $host) : ()),
                                  ($port ? (LocalPort => $port) : ()),
                                  ($queue ? (Listen => $queue)  : ()));
        return "${class}::new: Unable to create HTTP::Daemon object"
            unless $http;
        $URI = URI->new($http->url);
        $self->{__host} = $URI->host;
        $self->{__port} = $URI->port;
        $self->{__daemon} = $http;

        # Remove those we've processed
        delete @args{qw(host port queue)};
    }
    $resp = HTTP::Response->new();
    return "${class}::new: Unable to create HTTP::Response object"
        unless $resp;
    $resp->header(# This is essentially the same string returned by the
                  # default "identity" method that may be loaded from a
                  # XPL file. But it hasn't been loaded yet, and may not
                  # be, hence we set it here (possibly from option values)
                  RPC_Server   => $self->{__version},
                  RPC_Encoding => 'XML-RPC');
    $resp->code(RC_OK);
    $resp->message('OK');
    $self->{__response} = $resp;

    $self->{__path}            = $args{path} || '';
    $self->{__started}         = 0;
    $self->{__method_table}    = {};
    $self->{__method_class}    = $args{method_class} || 'RPC::XML::Method';
    $self->{__requests}        = 0;
    $self->{__auto_methods}    = $args{auto_methods} || 0;
    $self->{__auto_updates}    = $args{auto_updates} || 0;
    $self->{__debug}           = $args{debug} || 0;
    $self->{__parser}          = RPC::XML::Parser->new();
    $self->{__xpl_path}        = $args{xpl_path} || [];

    $self->add_default_methods unless ($args{no_default});

    # Remove the args we've already dealt with directly
    delete @args{qw(no_default no_http debug path server_name server_version)};
    # Copy the rest over untouched
    $self->{$_} = $args{$_} for (keys %args);

    $self;
}

# Most of these tiny subs are accessors to the internal hash keys. They not
# only control access to the internals, they ease sub-classing.

sub version { $RPC::XML::Server::VERSION }

sub url
{
    my $self = shift;

    return $self->{__daemon}->url if $self->{__daemon};
    return undef unless ($self->{__host});

    "http://$self->{__host}:$self->{__port}$self->{__path}";
}

sub product_tokens
{
    sprintf "%s/%s", (ref $_[0] || $_[0]), $_[0]->version;
}

# This fetches/sets the internal "started" timestamp
sub started
{
    my $self = shift;
    my $set  = shift || 0;

    my $old = $self->{__started} || 0;
    $self->{__started} = time if $set;

    $old;
}

sub path     { shift->{__path} }
sub host     { shift->{__host} }
sub port     { shift->{__port} }
sub requests { shift->{__requests} }
sub response { shift->{__response} }

# Get/set the search path for XPL files
sub xpl_path
{
    my $self = shift;
    my $ret = $self->{__xpl_path};

    $self->{__xpl_path} = $_[0] if ($_[0] and ref($_[0]) eq 'ARRAY');
    $ret;
}

###############################################################################
#
#   Sub Name:       add_method
#
#   Description:    Add a funtion-to-method mapping to the server object.
#
#   Arguments:      NAME      IN/OUT  TYPE      DESCRIPTION
#                   $self     in      ref       Object to add to
#                   $meth     in      scalar    Hash ref of data or file name
#
#   Globals:        None.
#
#   Environment:    None.
#
#   Returns:        Success:    $self
#                   Failure:    error string
#
###############################################################################
sub add_method
{
    my $self = shift;
    my $meth = shift;

    my ($name, $val);
    my $class = $self->{__method_class};

    my $me = ref($self) . '::add_method';

    if (! ref($meth))
    {
        $val = $self->method_from_file($meth);
        if (! ref($val))
        {
            return "$me: Error loading from file $meth: $val";
        }
        else
        {
            $meth = $val;
        }
    }
    elsif (ref($meth) eq 'HASH')
    {
        $meth = $class->new($meth);
    }
    elsif (! UNIVERSAL::isa($meth, $class))
    {
        return "$me: Method argument must be a $class object, a hash " .
            'reference or a file name';
    }

    # Do some sanity-checks
    return "$me: Method missing required data; check name, code and/or " .
        'signature' unless $meth->is_valid;

    $name = $meth->name;
    $self->{__method_table}->{$name} = $meth;

    $self;
}

=pod

=head1 NAME

RPC::XML::Server - A sample server implementation based on RPC::XML

=head1 SYNOPSIS

    use RPC::XML::Server;

    ...
    $srv = RPC::XML::Server->new(port => 9000);
    # Several of these, most likely:
    $srv->add_method(...);
    ...
    $srv->server_loop; # Never returns

=head1 DESCRIPTION

This is a sample XML-RPC server built upon the B<RPC::XML> data classes, and
using B<HTTP::Daemon> and B<HTTP::Response> for the communication layer.

=head1 USAGE

Use of the B<RPC::XML::Server> is based on an object model. A server is
instantiated from the class, methods (subroutines) are made public by adding
them through the object interface, and then the server object is responsible
for dispatching requests (and possibly for the HTTP listening, as well).

=head2 Methods

The following methods are provided by the B<RPC::XML::Server> class. Unless
otherwise explicitly noted, all methods return the invoking object reference
upon success, and a non-reference error string upon failure.

=over 4

=item new(OPTIONS)

Creates a new object of the class and returns the blessed reference. Depending
on the options, the object will contain some combination of an HTTP listener,
a pre-populated B<HTTP::Response> object, a B<RPC::XML::Parser> object, and
a dispatch table with the set of default methods pre-loaded. The options that
B<new> accepts are passed as a hash of key/value pairs (not a hash reference).
The accepted options are:

=over 4

=item B<no_http>

If passed with a C<true> value, prevents the creation and storage of the
B<HTTP::Daemon> and the pre-configured B<HTTP::Response> objects. This allows
for deployment of a server object in other environments. Note that if this is
set, the B<accept_loop> method described below will silently return
immediately.

=item B<no_default>

If passed with a C<true> value, prevents the loading of the default methods
provided with the B<RPC::XML> distribution. These may be later loaded using
the B<add_default_methods> interface described later. The methods themselves
are described below (see L<"The Default Methods Provided">).

=item B<path>

=item B<host>

=item B<port>

=item B<queue>

These four are mainly relevant only to HTTP-based implementations. The last
three are not used at all if C<no_http> is set. The B<path> argument sets the
additional URI path information that clients would use to contact the server.
Internally, it is not used except in outgoing status and introspection
reports.  The B<host>, B<port> and B<queue> arguments are passed to the
B<HTTP::Daemon> constructor if they are passed. They set the hostname, TCP/IP
port, and socket listening queue, respectively. Again, they are not used if
the C<no_http> argument was set.

=item B<xpl_path>

If you plan to add methods to the server object by passing filenames to the
C<add_method> call, this argument may be used to specify one or more
additional directories to be searched when the passed-in filename is a
relative path. The value for this must be an array reference. See also
B<add_method> and B<xpl_path>, below.

=item B<auto_methods>

If specified and set to a true value, enables the automatic searching for a
requested remote method that is unknown to the server object handling the
request. If set to "no" (or not set at all), then a request for an unknown
function causes the object instance to report an error. If the routine is
still not found, the error is reported. Enabling this is a security risk, and
should only be permitted by a server administrator with fully informed
acknowledgement and consent.

=item B<auto_updates>

If specified and set to a "true" value, enables the checking of the
modification time of the file from which a method was originally loaded. If
the file has changed, the method is re-loaded before execution is handed
off. As with the auto-loading of methods, this represents a security risk, and
should only be permitted by a server administrator with fully informed
acknowledgement and consent.

=item B<method_class>

By default, the server class uses the B<RPC::XML::Method> class to manage the
manipulation and tracking of the methods the server objects make available. If
the developer chooses to sub-class this method implementation (or even provide
a completely new one), the name of the class must be passed in via this
parameter. It will be used in all the internal creation/manipulation routines
within the server class.

=back

Any other keys in the options hash not explicitly used by the constructor are
copied over verbatim onto the object, for the benefit of sub-classing this
class. All internal keys are prefixed with "C<__>" to avoid confusion. Feel
free to use this prefix only if you wish to re-introduce confusion.

=item version

Returns the version string associated with this package.

=item product_tokens

This returns the identifying string for the server, in the format
"C<NAME/VERSION>" consistent with other applications such as Apache and
B<LWP>. It is provided here as part of the compatibility with B<HTTP::Daemon>
that is required for effective integration with B<Net::Server>.

=item url

This returns the HTTP URL that the server will be responding to, when it is in
the connection-accept loop. If the server object was created without a
built-in HTTP listener, then this method returns C<undef>.

=item requests

Returns the number of requests this server object has marshalled. Note that in
multi-process environments (such as Apache or Net::Server::PreFork) the value
returned will only reflect the messages dispatched by the specific process
itself.

=item response

Each instance of this class (and any subclasses that do not completely
override the C<new> method) creates and stores an instance of
B<HTTP::Response>, which is then used by the B<HTTP::Daemon> or B<Net::Server>
processing loops in constructing the response to clients. The response object
has all common headers pre-set for efficiency. This method returns a reference
to that object.

=item started([BOOL])

Gets and possibly sets the clock-time when the server starts accepting
connections. If a value is passed that evaluates to true, then the current
clock time is marked as the starting time. In either case, the current value
is returned. The clock-time is based on the internal B<time> command of Perl,
and thus is represented as an integer number of seconds since the system
epoch. Generally, it is suitable for passing to either B<localtime> or to the
C<time2iso8601> routine exported by the B<RPC::XML> package.

=item add_method(FILE | HASHREF)

This adds a new published method to the server object that invokes it. The
new method may be specified in one of two ways: as a filename or as a hash
reference.

If passed as a hash reference, the following keys are expected:

=over 4

=item B<name>

The published (externally-visible) name for the method.

=item B<version>

An optional version stamp. Not used internally, kept mainly for informative
purposes.

=item B<hidden>

If passed and evaluates to a C<true> value, then the method should be hidden
from any introspection API implementations. This parameter is optional, the
default behavior being to make the method publically-visible.

=item B<code>

A code reference to the actual Perl subroutine that handles this method. A
symbolic reference is not accepted. The value can be passed either as a
reference to an existing routine, or possibly as a closure. See
L</"How Methods are Called"> for the semantics the referenced subroutine must
follow.

=item B<signature>

A list reference of the signatures by which this routine may be invoked. Every
method has at least one signature. Though less efficient for cases of exactly
one signature, a list reference is always used for sake of consistency.

=item B<help>

Optional documentation text for the method. This is the text that would be
returned, for example, by a B<system.methodHelp> call (providing the server
has such an externally-visible method).

=back

If a file is passed, then it is expected to be in the XML-based format,
described in the B<RPC::XML::Method> manual (see L<RPC::XML::Method>). If the
name passed is not an absolute pathname, then the file will be searched for
in any directories specified when the object was instantiated, then in the
directory into which this module was installed, and finally in the current
working directory. If the operation fails, the return value will be a
non-reference, an error message. Otherwise, the return value is the object
reference.

For more on the creation and manipulation of methods as objects, see
L<RPC::XML::Method>.

=item xpl_path([LISTREF])

Get and/or set the object-specific search path for C<*.xpl> files (files that
specify methods) that are specified in calls to B<add_method>, above. If a
list reference is passed, it is installed as the new path (each element of the
list being one directory name to search). Regardless of argument, the current
path is returned as a list reference. When a file is passed to B<add_method>,
the elements of this path are searched first, in order, before the
installation directory or the current working directory are searched.

=item get_method(NAME)

Returns a reference to an object of the class B<RPC::XML::Method>, which is
the current binding for the published method NAME. If there is no such method
known to the server, then C<undef> is returned. The object is implemented as a
hash, and has the same key and value pairs as for C<add_method>, above. Thus,
the reference returned is suitable for passing back to C<add_method>. This
facilitates temporary changes in what a published name maps to. Note that this
is a referent to the object as stored on the server object itself, and thus
changes to it could affect the behavior of the server.

=item server_loop(HASH)

Enters the connection-accept loop, which generally does not return. This is
the C<accept()>-based loop of B<HTTP::Daemon> if the object was created with
an instance of that class as a part. Otherwise, this enters the run-loop of
the B<Net::Server> class. It listens for requests, and marshalls them out via
the C<dispatch> method described below. It answers HTTP-HEAD requests
immediately (without counting them on the server statistics) and efficiently
by using a cached B<HTTP::Response> object.

Because infinite loops requiring a C<HUP> or C<KILL> signal to terminate are
generally in poor taste, the B<HTTP::Daemon> side of this sets up a localized
signal handler which causes an exit when triggered. By default, this is
attached to the C<INT> signal. If the B<Net::Server> module is being used
instead, it provides its own signal management.

The arguments, if passed, are interpreted as a hash of key/value options (not
a hash reference, please note). For B<HTTP::Daemon>, only one is recognized:

=over 4

=item B<signal>

If passed, should be the traditional name for the signal that should be bound
to the exit function. The user is responsible for not passing the name of a
non-existent signal, or one that cannot be caught. If the value of this
argument is 0 (a C<false> value) or the string C<B<NONE>>, then the signal
handler will I<not> be installed, and the loop may only be broken out of by
killing the running process (unless other arrangements are made within the
application).

=back

The options that B<Net::Server> responds to are detailed in the manual pages
for that package. All options passed to C<server_loop> in this situation are
passed unaltered to the C<run()> method in B<Net::Server>.

=item dispatch(REQUEST)

This is the server method that actually manages the marshalling of an incoming
request into an invocation of a Perl subroutine. The parameter passed in may
be one of: a scalar containing the full XML text of the request, a scalar
reference to such a string, or a pre-constructed B<RPC::XML::request> object.
Unless an object is passed, the text is parsed with any errors triggering an
early exit. Once the object representation of the request is on hand, the
parameter data is extracted, as is the method name itself. The call is sent
along to the appropriate subroutine, and the results are collated into an
object of the B<RPC::XML::response> class, which is returned. Any non-reference
return value should be presumed to be an error string. If the dispatched
method encountered some sort of error, it will not be propagated upward here,
but rather encoded as an object of the B<RPC::XML::fault> class, and returned
as the result of the dispatch. This distinguishes between server-centric
errors, and general run-time errors.

=item add_default_methods([DETAILS])

This method adds all the default methods (those that are shipped with this
extension) to the calling server object. The files are denoted by their
C<*.xpl> extension, and are installed into the same directory as this
B<Server.pm> file. The set of default methods are described below (see
L<"The Default Methods Provided">).

If any names are passed as a list of arguments to this call, then only those
methods specified are actually loaded. If the C<*.xpl> extension is absent on
any of these names, then it is silently added for testing purposes. Note that
the methods shipped with this package have file names without the leading
"C<status.>" part of the method name. If the very first element of the list of
arguments is "C<except>" (or "C<-except>"), then the rest of the list is
treated as a set of names to I<not> load, while all others do get read. The
B<Apache::RPC::Server> module uses this to prevent the loading of the default
C<system.status> method while still loading all the rest of the defaults. (It
then provides a more Apache-centric status method.)

=item add_methods_in_dir(DIR, [DETAILS])

This is exactly like B<add_default_methods> above, save that the caller
specifies which directory to scan for C<*.xpl> files. In fact, the defaults
routine simply calls this routine with the installation directory as the
first argument. The definition of the additional arguments is the same as
above.

=back

=head2 Specifying Server-Side Remote Methods

Specifying the methods themselves can be a tricky undertaking. Some packages
(in other languages) delegate a specific class to handling incoming requests.
This works well, but it can lead to routines not intended for public
availability to in fact be available. There are also issues around the access
that the methods would then have to other resources within the same running
system.

The approach taken by B<RPC::XML::Server> (and the B<Apache::RPC::Server>
subclass of it) require that methods be explicitly published in one of the
several ways provided. Methods may be added directly within code by using
C<add_method> as described above, with full data provided for the code
reference, signature list, etc. The C<add_method> technique can also be used
with a file that conforms to a specific XML-based format (detailed in the
manual page for the B<RPC::XML::Method> class, see L<RPC::XML::Method>). Entire
directories of files may be added using C<add_methods_in_dir>, which merely
reads the given directory for files that appear to be method definitions.

=head2 How Methods Are Called

When a routine is called via the server dispatcher, it is called with the
arguments that the client request passed, plus one. The extra argument is the
first one passed, a reference to a B<RPC::XML::Server> object (or a subclass
thereof). This is derived from a hash reference, and will include two
special keys:

=over 4

=item method_name

This is the name by which the method was called in the client. Most of the
time, this will probably be consistent for all calls to the server-side
method. But it does not have to be, hence the passing of the value.

=item signature

This is the signature that was used, when dispatching. Perl has a liberal
view of lists and scalars, so it is not always clear what arguments the client
specifically has in mind when calling the method. The signature is an array
reference containing one or more datatypes, each a simple string. The first
of the datatypes specifies the expected return type. The remainder (if any)
refer to the arguments themselves.

=back

Note that by passing the server object reference first, the methods themselves
are essentially expected to behave as actual methods of the server class, as
opposed to ordinary functions. Of course, they can also discard the initial
argument completely.

The methods should not make (excessive) use of global variables. Likewise,
methods should not change their package space within the definition. Bad
Things Could Happen.

=head2 The Default Methods Provided

The following methods are provided with this package, and are the ones
installed on newly-created server objects unless told not to. These are
identified by their published names, as they are compiled internally as
anonymous subroutines and thus cannot be called directly:

=over 4

=item B<system.identity>

Returns a B<string> value identifying the server name, version, and possibly a
capability level. Takes no arguments.

=item B<system.introspection>

Returns a series of B<struct> objects that give overview documentation of one
or more of the published methods. It may be called with a B<string>
identifying a single routine, in which case the return value is a
B<struct>. It may be called with an B<array> of B<string> values, in which
case an B<array> of B<struct> values, one per element in, is returned. Lastly,
it may be called with no input parameters, in which case all published
routines are documented.  Note that routines may be configured to be hidden
from such introspection queries.

=item B<system.listMethods>

Returns a list of the published methods or a subset of them as an B<array> of
B<string> values. If called with no parameters, returns all (non-hidden)
method names. If called with a single B<string> pattern, returns only those
names that contain the string as a substring of their name (case-sensitive,
and this is I<not> a regular expression evaluation).

=item B<system.methodHelp>

Takes either a single method name as a B<string>, or a series of them as an
B<array> of B<string>. The return value is the help text for the method, as
either a B<string> or B<array> of B<string> value. If the method(s) have no
help text, the string will be null.

=item B<system.methodSignature>

As above, but returns the signatures that the method accepts, as B<array> of
B<string> representations. If only one method is requests via a B<string>
parameter, then the return value is the corresponding array. If the parameter
in is an B<array>, then the returned value will be an B<array> of B<array> of
B<string>.

=item B<system.multicall>

This is a simple implementation of composite function calls in a single
request. It takes an B<array> of B<struct> values. Each B<struct> has at least
a C<methodName> member, which provides the name of the method to call. If
there is also a C<params> member, it refers to an B<array> of the parameters
that should be passed to the call.

=item B<system.status>

Takes no arguments and returns a B<struct> containing a number of system
status values including (but not limited to) the current time on the server,
the time the server was started (both of these are returned in both ISO 8601
and UNIX-style integer formats), number of requests dispatched, and some
identifying information (hostname, port, etc.).

=back

In addition, each of these has an accompanying help file in the C<methods>
sub-directory of the distribution.

These methods are installed as C<*.xpl> files, which are generated from files
in the C<methods> directory of the distribution using the B<make_method> tool
(see L<make_method>). The files there provide the Perl code that implements
these, their help files and other information.

=head1 DIAGNOSTICS

Unless explicitly stated otherwise, all methods return some type of reference
on success, or an error string on failure. Non-reference return values should
always be interpreted as errors unless otherwise noted.

=head1 CAVEATS

This began as a reference implementation in which clarity of process and
readability of the code took precedence over general efficiency. It is now
being maintained as production code, but may still have parts that could be
written more efficiently.

=head1 CREDITS

The B<XML-RPC> standard is Copyright (c) 1998-2001, UserLand Software, Inc.
See <http://www.xmlrpc.com> for more information about the B<XML-RPC>
specification.

=head1 LICENSE

This module is licensed under the terms of the Artistic License that covers
Perl. See <http://language.perl.com/misc/Artistic.html> for the
license.

=head1 SEE ALSO

L<RPC::XML>, L<RPC::XML::Client>, L<RPC::XML::Parser>

=head1 AUTHOR

Randy J. Ray <rjray@blackperl.com>

=cut

__END__

###############################################################################
#
#   Sub Name:       method_from_file
#
#   Description:    Create a RPC::XML::Method (or derivative) object from the
#                   passed-in file name, using the object's search path if the
#                   name is not already absolute.
#
#   Arguments:      NAME      IN/OUT  TYPE      DESCRIPTION
#                   $self     in      ref       Object of this class
#                   $file     in      scalar    Name of file to load
#
#   Returns:        Success:    Method-object reference
#                   Failure:    error message
#
###############################################################################
sub method_from_file
{
    my $self = shift;
    my $file = shift;

    my $class = $self->{__method_class};

    unless (File::Spec->file_name_is_absolute($file))
    {
        my ($path, @path);
        push(@path, @{$self->xpl_path}) if (ref $self);
        for (@path, @XPL_PATH)
        {
            $path = File::Spec->catfile($_, $file);
            if (-e $path) { $file = File::Spec->canonpath($path); last; }
        }
    }
    # Just in case it still didn't appear in the path, we really want an
    # absolute path:
    $file = File::Spec->rel2abs($file)
        unless (File::Spec->file_name_is_absolute($file));

    $class->new($file);
}

###############################################################################
#
#   Sub Name:       get_method
#
#   Description:    Get the current binding for the remote-side method $name.
#                   Returns undef if the method is not defined for the server
#                   instance.
#
#   Arguments:      NAME      IN/OUT  TYPE      DESCRIPTION
#                   $self     in      ref       Class instance
#                   $name     in      scalar    Name of the method being looked
#                                                 up
#
#   Globals:        None.
#
#   Environment:    None.
#
#   Returns:        Success:    Method-class reference
#                   Failure:    undef
#
###############################################################################
sub get_method
{
    my $self = shift;
    my $name = shift;

    return undef unless ($name and $self->{__method_table}->{$name});

    $self->{__method_table}->{$name};
}

###############################################################################
#
#   Sub Name:       server_loop
#
#   Description:    Enter a server-loop situation, using the accept() loop of
#                   HTTP::Daemon if $self has such an object, or falling back
#                   Net::Server otherwise.
#
#   Arguments:      NAME      IN/OUT  TYPE      DESCRIPTION
#                   $self     in      ref       Object of this class
#                   %args     in      hash      Additional parameters to set up
#                                                 before calling the superclass
#                                                 Run method
#
#   Globals:        None.
#
#   Environment:    None.
#
#   Returns:        string if error, otherwise void
#
###############################################################################
sub server_loop
{
    my $self = shift;
    my %args = @_;

    if ($self->{__daemon})
    {
        my ($conn, $req, $resp, $reqxml, $return, $respxml, $exit_now,
            $timeout);

        # Localize and set the signal handler as an exit route
        if (exists $args{signal})
        {
            local $SIG{$args{signal}} = sub { $exit_now++; }
                unless ($args{signal} eq 'NONE');
        }
        else
        {
            local $SIG{INT} = sub { $exit_now++; };
        }

        $self->started('set');
        $exit_now = 0;
        $timeout = $self->{__daemon}->timeout(1);
        while (1)
        {
            $conn = $self->{__daemon}->accept;

            last if $exit_now;
            next unless $conn;
            $self->process_request($conn);
            $conn->close;
            undef $conn; # Free up any lingering resources
        }

        $self->{__daemon}->timeout($timeout);
    }
    else
    {
        # This is the Net::Server block

        # Don't do this next part if they've already given a port, or are
        # pointing to a config file:

        unless ($args{conf_file} or $args{port})
        {
            $args{port} = $self->{port} || $self->{__port} || 9000;
            $args{host} = $self->{host} || $self->{__host} || '*';
        }

        # Try to load the Net::Server::MultiType module
        eval { require Net::Server::MultiType; };
        return ref($self) .
            "::server_loop: Error loading Net::Server::MultiType: $@"
                if ($@);
        unshift(@RPC::XML::Server::ISA, 'Net::Server::MultiType');

        $self->started('set');
        # ...and we're off!
        $self->run(%args);
    }

    return;
}

###############################################################################
#
#   Sub Name:       post_configure_loop
#
#   Description:    Called by the Net::Server classes after all the config
#                   steps have been done and merged.
#
#   Arguments:      NAME      IN/OUT  TYPE      DESCRIPTION
#                   $self     in      ref       Class object
#
#   Globals:        None.
#
#   Environment:    None.
#
#   Returns:        $self
#
###############################################################################
sub post_configure_hook
{
    my $self = shift;

    $self->{__host} = $self->{server}->{host};
    $self->{__port} = $self->{server}->{port};

    $self;
}

###############################################################################
#
#   Sub Name:       pre_loop_hook
#
#   Description:    Called by Net::Server classes after the post_bind method,
#                   but before the socket-accept loop starts.
#
#   Arguments:      NAME      IN/OUT  TYPE      DESCRIPTION
#                   $self     in      ref       Object instance
#
#   Globals:       %ENV
#
#   Environment:    None.
#
#   Returns:        $self
#
###############################################################################
sub pre_loop_hook
{
    # We have to disable the __DIE__ handler for the sake of XML::Parser::Expat
    $SIG{__DIE__} = '';
}

###############################################################################
#
#   Sub Name:       process_request
#
#   Description:    This is provided for the case when we run as a subclass
#                   of Net::Server.
#
#   Arguments:      NAME      IN/OUT  TYPE      DESCRIPTION
#                   $self     in      ref       This class object
#                   $conn     in      ref       If present, it's a connection
#                                                 object from HTTP::Daemon
#
#   Globals:        None.
#
#   Environment:    None.
#
#   Returns:        void
#
###############################################################################
sub process_request
{
    my $self = shift;
    my $conn = shift;

    my ($req, $reqxml, $resp, $respxml);

    unless ($conn and ref($conn))
    {
        $conn = $self->{server}->{client};
        bless $conn, 'HTTP::Daemon::ClientConn';
        ${*$conn}{'httpd_daemon'} = $self;
    }

    while ($req = $conn->get_request)
    {
        if ($req->method eq 'HEAD')
        {
            # The HEAD method will be answered with our return headers,
            # both as a means of self-identification and a verification
            # of live-status. All the headers were pre-set in the cached
            # HTTP::Response object. Also, we don't count this for stats.
            $conn->send_response($self->{__response});
        }
        elsif ($req->method eq 'POST')
        {
            $reqxml = $req->content;
            # Dispatch will always return a RPC::XML::response
            $resp = $self->dispatch(\$reqxml);
            $respxml = $resp->as_string;
            # Now clone the pre-fab response and add content
            $resp = $self->{__response}->clone;
            $resp->content($respxml);
            $conn->send_response($resp);
            undef $resp;
        }
        else
        {
            $conn->send_error(RC_FORBIDDEN);
        }
    }

    return;
}

###############################################################################
#
#   Sub Name:       dispatch
#
#   Description:    Route the request by parsing it, determining what the
#                   Perl routine should be, etc.
#
#   Arguments:      NAME      IN/OUT  TYPE      DESCRIPTION
#                   $self     in      ref       Object of this class
#                   $xml      in      ref       Reference to the XML text, or
#                                                 a RPC::XML::request object.
#                                                 If it is a listref, assume
#                                                 [ name, @args ].
#                   $reftable in      hashref   If present, a reference to the
#                                                 current-running table of
#                                                 back-references
#
#   Globals:        %extended_types
#                   $RPC::XML::Server::INSTANCE
#                   $RPC::XML::Compatible
#
#   Environment:    None.
#
#   Returns:        RPC::XML::response object
#
###############################################################################
sub dispatch
{
    my $self     = shift;
    my $xml      = shift;

    my ($reqobj, @data, @paramtypes, $resptype, $response, $signature, $name,
        $meth);

    if (ref($xml) eq 'SCALAR')
    {
        $reqobj = $self->{__parser}->parse($$xml);
        return RPC::XML::response
            ->new(RPC::XML::fault->new(200, "XML parse failure: $reqobj"))
                unless (ref $reqobj);
    }
    elsif (ref($xml) eq 'ARRAY')
    {
        # This is sort of a cheat-- we're more or less going backwards by one
        # step, in order to allow the loop below to cover this case as well.
        $reqobj = RPC::XML::request->new(shift(@$xml), @$xml);
    }
    elsif (UNIVERSAL::isa($xml, 'RPC::XML::request'))
    {
        $reqobj = $xml;
    }
    else
    {
        $reqobj = $self->{__parser}->parse($xml);
        return RPC::XML::response
            ->new(RPC::XML::fault->new(200, "XML parse failure: $reqobj"))
                unless (ref $reqobj);
    }

    @data = @{$reqobj->args};
    # First test: do we have this method?
    $name = $reqobj->name;
    if (! defined($meth = $self->get_method($name)))
    {
        if ($self->{__auto_methods})
        {
            # Try to load this dynamically on the fly, from any of the dirs
            # that are in this object's @xpl_path
            (my $loadname = $name) =~ s/^system\.//;
            $self->add_method("$loadname.xpl");
            # If method is still not in the table, we were unable to load it
            return RPC::XML::response
                ->new(RPC::XML::fault->new(300, "Unknown method: $name"))
                    unless ($meth = $self->get_method($name));
        }
        else
        {
            return RPC::XML::response
                ->new(RPC::XML::fault->new(300, "Unknown method: $name"));
        }
    }
    # Check the mod-time of the file the method came from, if the test is on
    if ($self->{__auto_updates} && $meth->{file} &&
        ($meth->{mtime} < (stat $meth->{file})[9]))
    {
        $ret = $meth->reload;
        return RPC::XML::response
            ->new(RPC::XML::fault
                  ->new(302, "Reload of method $name failed: $ret"))
                unless (ref $ret);
    }

    # Create the param list.
    # The type for the response will be derived from the matching signature
    @paramtypes = map { $_->type } @data;
    $signature = join(' ', @paramtypes);
    $resptype = $meth->match_signature($signature);
    # Since there must be at least one signature with a return value (even
    # if the param list is empty), this tells us if the signature matches:
    return RPC::XML::response
        ->new(RPC::XML::fault->new(301,
                                   "method $name nas no matching " .
                                   'signature for the argument list'))
            unless ($resptype);

    # Set up these for the use of the called method
    local $self->{signature} = [ $resptype, @paramtypes ];
    local $self->{method_name} = $name;
    # Now take a deep breath and call the method with the arguments
    eval {
        $response = &{$meth->{code}}($self, map { $_->value } @data);
    };
    if ($@)
    {
        # Report a Perl-level error/failure
        $response = RPC::XML::fault->new(302,
                                         "Method $name returned error: $@");
    }
    $self->{__requests}++;
    $meth->{called}++;

    return RPC::XML::response->new($response);
}

###############################################################################
#
#   Sub Name:       call
#
#   Description:    This is an internal, end-run-around-dispatch() method to
#                   allow the RPC methods that this server has and knows about
#                   to call each other through their reference to the server
#                   object.
#
#   Arguments:      NAME      IN/OUT  TYPE      DESCRIPTION
#                   $self     in      ref       Object of this class
#                   $name     in      scalar    Name of the method to call
#                   @args     in      list      Arguments (if any) to pass
#
#   Globals:        None.
#
#   Environment:    None.
#
#   Returns:        Success:    return value of the call
#                   Failure:    error string
#
###############################################################################
sub call
{
    my $self = shift;
    my ($name, @args) = @_;

    my $meth;

    #
    # Two VERY important notes here: The values in @args are not pre-treated
    # in any way, so not only should the receiver understand what they're
    # getting, there's no signature checking taking place, either.
    #
    # Second, if the normal return value is not distinguishable from a string,
    # then the caller may not recognize if an error occurs.
    #

    my $response;

    if (! defined($meth = $self->get_method($name)))
    {
        # Try to load this dynamically on the fly, from any of the dirs that
        # are in this object's @xpl_path
        (my $loadname = $name) =~ s/^system\.//;
        $self->add_method("$loadname.xpl");
        $meth = $self->get_method($name);
    }
    # If the method is still not in the table, we were unable to load it
    return "Unknown method: $name" unless (ref $meth);
    # Check the mod-time of the file the method came from, if the test is on
    if ($self->{__auto_updates} && $meth->{file} &&
        ($meth->{mtime} < (stat $meth->{file})[9]))
    {
        $ret = $meth->reload;
        return "Reload of method $name failed: $ret" unless (ref $ret);
    }

    # Though we have no signature, we can still tell them what name was called
    local $self->{method_name} = $name;
    eval {
        $response = &{$meth->{code}}($self, @args);
    };
    if ($@)
    {
        # Report a Perl-level error/failure
        $response = $@;
    }

    $response;
}

###############################################################################
#
#   Sub Name:       add_default_methods
#
#   Description:    This adds all the methods that were shipped with this
#                   package, by threading through to add_methods_in_dir()
#                   with the global constant $INSTALL_DIR.
#
#   Arguments:      NAME      IN/OUT  TYPE      DESCRIPTION
#                   $self     in      ref       Object reference/static class
#                   @details  in      ref       Details of names to add or skip
#
#   Globals:        $INSTALL_DIR
#
#   Environment:    None.
#
#   Returns:        $self
#
###############################################################################
sub add_default_methods
{
    shift->add_methods_in_dir($INSTALL_DIR, @_);
}

###############################################################################
#
#   Sub Name:       add_methods_in_dir
#
#   Description:    This adds all methods specified in the directory passed,
#                   in accordance with the details specified.
#
#   Arguments:      NAME      IN/OUT  TYPE      DESCRIPTION
#                   $self     in      ref       Class instance
#                   $dir      in      scalar    Directory to scan
#                   @details  in      list      Possible hanky-panky with the
#                                                 list of methods to install
#
#   Globals:        None.
#
#   Environment:    None.
#
#   Returns:        $self
#
###############################################################################
sub add_methods_in_dir
{
    my $self = shift;
    my $dir = shift;
    my @details = @_;

    my $negate = 0;
    my $detail = 0;
    my (%details, $ret);

    if (@details)
    {
        $detail = 1;
        if ($details[0] =~ /^-?except/i)
        {
            $negate = 1;
            shift(@details);
        }
        for (@details) { $_ .= '.xpl' unless /\.xpl$/ }
        @details{@details} = (1) x @details;
    }

    local(*D);
    opendir(D, $dir) || return "Error opening $dir for reading: $!";
    my @files = grep($_ =~ /\.xpl$/, readdir(D));
    closedir D;

    for (@files)
    {
        # Use $detail as a short-circuit to avoid the other tests when we can
        next if ($detail and
                 $negate ? $details{$_} : ! $details{$_});
        # n.b.: Giving the full path keeps add_method from having to search
        $ret = $self->add_method(File::Spec->catfile($dir, $_));
        return $ret unless ref $ret;
    }

    $self;
}