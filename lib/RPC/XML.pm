###############################################################################
#
# This file copyright (c) 2001-2009 Randy J. Ray, all rights reserved
#
# Copying and distribution are permitted under the terms of the Artistic
# License 2.0 (http://www.opensource.org/licenses/artistic-license-2.0.php) or
# the GNU LGPL (http://www.opensource.org/licenses/lgpl-2.1.php).
#
###############################################################################
#
#   Description:    This module provides the core XML <-> RPC conversion and
#                   structural management.
#
#   Functions:      This module contains many, many subclasses. Better to
#                   examine them individually.
#
#   Libraries:      RPC::XML::base64 uses MIME::Base64
#
#   Global Consts:  $VERSION
#
###############################################################################

package RPC::XML;

use 5.006001;
use strict;
use warnings;
use vars qw(@EXPORT @EXPORT_OK %EXPORT_TAGS @ISA $VERSION $ERROR
            %xmlmap $xmlre $ENCODING $FORCE_STRING_ENCODING $ALLOW_NIL);
use subs qw(time2iso8601 smart_encode utf8_downgrade);

## no critic (ProhibitSubroutinePrototypes)

BEGIN
{
    %xmlmap = ( '>' => '&gt;',   '<' => '&lt;', '&' => '&amp;',
                '"' => '&quot;', "'" => '&apos;');
    $xmlre = join('', keys %xmlmap); $xmlre = qr/([$xmlre])/;

    # Default encoding:
    $ENCODING = 'us-ascii';

    # force strings?
    $FORCE_STRING_ENCODING = 0;

    # Allow the <nil /> extension?
    $ALLOW_NIL = 0;

    # Cribbed from the UTF-8 fixes in HTTP::Message, this may be discardable
    # once full encoding support is in place:
    *utf8_downgrade = defined(&utf8::downgrade) ?
        \&utf8::downgrade : sub { };
}

use Scalar::Util qw(blessed reftype);
require Exporter;

@ISA = qw(Exporter);
@EXPORT_OK = qw(time2iso8601 smart_encode
                RPC_BOOLEAN RPC_INT RPC_I4 RPC_DOUBLE RPC_DATETIME_ISO8601
                RPC_BASE64 RPC_STRING RPC_NIL
                $ENCODING $FORCE_STRING_ENCODING $ALLOW_NIL);
%EXPORT_TAGS = (types => [ qw(RPC_BOOLEAN RPC_INT RPC_I4 RPC_DOUBLE RPC_STRING
                              RPC_DATETIME_ISO8601 RPC_BASE64 RPC_NIL) ],
                all   => [ @EXPORT_OK ]);

$VERSION = '1.47';
$VERSION = eval $VERSION; ## no critic

# Global error string
$ERROR = '';

# All of the RPC_* functions are convenience-encoders
sub RPC_STRING           ($)   { RPC::XML::string->new($_[0]) }
sub RPC_BOOLEAN          ($)   { RPC::XML::boolean->new($_[0]) }
sub RPC_INT              ($)   { RPC::XML::int->new($_[0]) }
sub RPC_I4               ($)   { RPC::XML::i4->new($_[0]) }
sub RPC_I8               ($)   { RPC::XML::i8->new($_[0]) }
sub RPC_DOUBLE           ($)   { RPC::XML::double->new($_[0]) }
sub RPC_DATETIME_ISO8601 ($)   { RPC::XML::datetime_iso8601->new($_[0]) }
sub RPC_BASE64           ($;$) { RPC::XML::base64->new(@_) }
sub RPC_NIL              ()    { RPC::XML::nil->new() }

# This is a dead-simple ISO8601-from-UNIX-time stringifier. Always expresses
# time in UTC. The format isn't strictly ISO8601, though, as the XML-RPC spec
# fucked it up.
sub time2iso8601
{
    my $time = shift || time;
    my $zone = shift || '';

    my @time = gmtime($time);
    $time = sprintf("%4d-%02d-%02dT%02d:%02d:%02dZ",
                    $time[5] + 1900, $time[4] + 1, @time[3, 2, 1, 0]);
    if ($zone)
    {
        my $char = $zone > 0 ? '+' : '-';
        chop $time; # Lose the Z if we're specifying a zone
        $time .= $char . sprintf('%02d:00', abs($zone));
    }

    $time;
}

# This is a (futile?) attempt to provide a "smart" encoding method that will
# take a Perl scalar and promote it to the appropriate RPC::XML::_type_.
{
    my $MaxInt      = 2147483647;
    my $MinInt      = -2147483648;
    my $MaxBigInt   = 9223372036854775807;
    my $MinBigInt   = -9223372036854775808;

    my $MaxDouble   = 1e37;
    my $MinDouble   = $MaxDouble * -1;

    sub smart_encode
    {
        my @values = @_;
        my ($type, $seenrefs, @newvalues);

        # Look for sooper-sekrit pseudo-blessed hashref as first argument.
        # It means this is a recursive call, and it contains a map of any
        # references we've already seen.
        if ((blessed $values[0]) && ($values[0]->isa('RPC::XML::refmap')))
        {
            # Peel it off of the list
            $seenrefs = shift(@values);
        }
        else
        {
            # Create one just in case we need it
            $seenrefs = bless {}, 'RPC::XML::refmap';
        }

        foreach (@values)
        {
            if (! defined $_)
            {
                $type = $ALLOW_NIL ?
                    RPC::XML::nil->new() : RPC::XML::string->new('');
            }
            elsif (ref $_)
            {
                # Skip any that we've already seen
                next if $seenrefs->{$_}++;

                if (blessed $_)
                {
                    if ($_->isa('RPC::XML::datatype'))
                    {
                        # Pass through any that have already been encoded
                        $type = $_;
                    }
                    elsif ($_->isa('DateTime'))
                    {
                        $type = RPC::XML::datetime_iso8601
                            ->new($_->clone->set_time_zone('UTC')->iso8601);
                    }
                    else
                    {
                        # If the user passed in an object that didn't pass one
                        # of the above tests, we can't do anything with it:
                        my $type = blessed $_;
                        die "Un-convertable reference: $type, cannot use";
                    }
                }
                elsif (reftype($_) eq 'HASH')
                {
                    # Per RT 41063, to catch circular refs I can't delegate
                    # to the struct constructor, I have to create my own
                    # copy of the hash with locally-recursively-encoded
                    # values
                    my %newhash;
                    for my $key (keys %$_)
                    {
                        # Forcing this into a list-context *should* make the
                        # test be true even if the return value is a hard
                        # undef. Only if the return value is an empty list
                        # should this evaluate as false...
                        if (my @value = smart_encode($seenrefs, $_->{$key}))
                        {
                            $newhash{$key} = $value[0];
                        }
                    }

                    $type = RPC::XML::struct->new(\%newhash);
                }
                elsif (reftype($_) eq 'ARRAY')
                {
                    # This is a somewhat-ugly approach, but I don't want to
                    # dereference @$_, but I also want people to be able to
                    # pass array-refs in to this constructor and have them
                    # be treated as single elements, as one would expect
                    # (see RT 35106)
                    # Per RT 41063, looks like I get to deref $_ after all...
                    $type =
                        RPC::XML::array->new(from =>
                                             [ smart_encode($seenrefs, @$_) ]);
                }
                elsif (reftype($_) eq 'SCALAR')
                {
                    # This is a rare excursion into recursion, since the scalar
                    # nature (de-refed from the object, so no longer magic)
                    # will prevent further recursing.
                    $type = smart_encode($seenrefs, $$_);
                }
                else
                {
                    # If the user passed in a reference that didn't pass one
                    # of the above tests, we can't do anything with it:
                    my $type = reftype $_;
                    die "Un-convertable reference: $type, cannot use";
                }
            }
            # You have to check ints first, because they match the
            # next pattern too
            elsif (! $FORCE_STRING_ENCODING and /^[-+]?\d+$/
                   and $_ > $MinBigInt and $_ < $MaxBigInt)
            {
                $type = (abs($_) > $MaxInt) ? 'RPC::XML::i8' : 'RPC::XML::int';
                $type = $type->new($_);
            }
            # Pattern taken from perldata(1)
            elsif (! $FORCE_STRING_ENCODING and
                   /^([+-]?)(?=\d|\.\d)\d*(\.\d*)?([Ee]([+-]?\d+))?$/
                   and $_ > $MinDouble and $_ < $MaxDouble)
            {
                $type = RPC::XML::double->new($_);
            }
            # The XMLRPC spec only allows for the incorrect iso8601 format
            # without dashes, but dashes are part of the standard so we include
            # them (DateTime->now->iso8601 includes them).
            elsif (/
                       ^           # start
                       \d{4}       # 4 digit year
                       -?          # "optional" dash
                       [01]\d      # month
                       -?          # optional dash
                       [0123]\d    # day of month
                       T           # Yes, "T"
                       [012]\d:    # hours
                       [012345]\d: # min
                       [012345]\d  # seconds
                       (?:\.\d+)?  # optional fractional seconds
                       Z?          # optional "Z" to indicate UTC
                       $           # end
                   /x)
            {
                $type = RPC::XML::datetime_iso8601->new($_);
            }
            else
            {
                $type = RPC::XML::string->new($_);
            }

            push(@newvalues, $type);
        }

        return (wantarray ? @newvalues : $newvalues[0]);
    }
}

# This is a (mostly) empty class used as a common superclass for simple and
# complex types, so that their derivatives may be universally type-checked.
package RPC::XML::datatype;

sub type { my $class = ref($_[0]) || $_[0]; $class =~ s/.*://; $class }
sub is_fault { 0 }

###############################################################################
#
#   Package:        RPC::XML::simple_type
#
#   Description:    A base class for the simpler type-classes to inherit from,
#                   for default constructor, stringification, etc.
#
###############################################################################
package RPC::XML::simple_type;

use strict;
use base 'RPC::XML::datatype';

use Scalar::Util 'reftype';

# new - a generic constructor that presumes the value being stored is scalar
sub new
{
    my $class = shift;
    my $value = shift;

    $RPC::XML::ERROR = '';
    $class = ref($class) || $class;
    if (ref $value)
    {
        # If it is a scalar reference, just deref
        if (reftype($value) eq 'SCALAR')
        {
            $value = $$value;
        }
        else
        {
            # We can only manage scalar references (or blessed scalar refs)
            $RPC::XML::ERROR = "${class}::new: Cannot instantiate from a " .
                'reference not derived from scalar';
        }
    }
    bless \$value, $class;
}

# value - a generic accessor
sub value
{
    my $self = shift;

    $$self;
}

# as_string - return the value as an XML snippet
sub as_string
{
    my $self = shift;

    my $class;
    return unless ($class = ref($self));
    $class =~ s/^.*\://;
    $class =~ s/_/./g;
    substr($class, 0, 8) = 'dateTime' if (substr($class, 0, 8) eq 'datetime');

    "<$class>$$self</$class>";
}

# Serialization for simple types is just a matter of sending as_string over
sub serialize
{
    my ($self, $fh) = @_;

    my $str = $self->as_string;
    RPC::XML::utf8_downgrade($str);

    print $fh $str;
}

# The switch to serialization instead of in-memory strings means having to
# calculate total size in bytes for Content-Length headers:
sub length
{
    my $self = shift;

    RPC::XML::utf8_downgrade(my $str = $self->as_string);
    length($str);
}

###############################################################################
#
#   Package:        RPC::XML::int
#
#   Description:    Data-type class for integers
#
###############################################################################
package RPC::XML::int;

use strict;
use base 'RPC::XML::simple_type';

###############################################################################
#
#   Package:        RPC::XML::i4
#
#   Description:    Data-type class for i4. Forces data into an int object.
#
###############################################################################
package RPC::XML::i4;

use strict;
use base 'RPC::XML::simple_type';

###############################################################################
#
#   Package:        RPC::XML::i8
#
#   Description:    Data-type class for i8. Forces data into a 8-byte int.
#
###############################################################################
package RPC::XML::i8;

use strict;
use base 'RPC::XML::simple_type';

###############################################################################
#
#   Package:        RPC::XML::double
#
#   Description:    The "double" type-class
#
###############################################################################
package RPC::XML::double;

use strict;
use base 'RPC::XML::simple_type';

sub as_string
{
    my $self = shift;

    return unless (my $class = $self->type);
    (my $value = sprintf("%.20f", $$self)) =~ s/(\.\d+?)0+$/$1/;

    "<$class>$value</$class>";
}

###############################################################################
#
#   Package:        RPC::XML::string
#
#   Description:    The "string" type-class
#
###############################################################################
package RPC::XML::string;

use strict;
use base 'RPC::XML::simple_type';

# as_string - return the value as an XML snippet
sub as_string
{
    my $self = shift;

    my ($class, $value);

    return unless ($class = $self->type);

    ($value = defined $$self ? $$self : '' )
        =~ s/$RPC::XML::xmlre/$RPC::XML::xmlmap{$1}/ge;

    "<$class>$value</$class>";
}

###############################################################################
#
#   Package:        RPC::XML::boolean
#
#   Description:    The type-class for boolean data. Handles some "extra" cases
#
###############################################################################
package RPC::XML::boolean;

use strict;
use base 'RPC::XML::simple_type';

# This constructor allows any of true, false, yes or no to be specified
sub new
{
    my $class = shift;
    my $value = shift || 0;

    $RPC::XML::ERROR = '';
    if ($value =~ /true|yes|1/i)
    {
        $value = 1;
    }
    elsif ($value =~ /false|no|0/i)
    {
        $value = 0;
    }
    else
    {
        $class = ref($class) || $class;
        $RPC::XML::ERROR = "${class}::new: Value must be one of yes, no, " .
            'true, false, 1, 0 (case-insensitive)';
        return;
    }

    bless \$value, $class;
}

###############################################################################
#
#   Package:        RPC::XML::datetime_iso8601
#
#   Description:    This is the class to manage ISO8601-style date/time values
#
###############################################################################
package RPC::XML::datetime_iso8601;

use strict;
use base 'RPC::XML::simple_type';

use Scalar::Util 'reftype';

sub type { 'dateTime.iso8601' };

# Check the value passed in for sanity, and normalize the string representation
sub new
{
    my ($class, $value) = @_;

    $value = $$value if (ref($value) && reftype($value) eq 'SCALAR');

    if ($value && $value =~ /^(\d{4})-?([01]\d)-?([0123]\d)T
                             ([012]\d):([012345]\d):([012345]\d)(\.\d+)?
							 (Z|[-+]\d\d:\d\d)?$/x)
    {
        # This is the WRONG way to represent this, but it's the way it is
        # given in the spec, so assume that other implementations can only
        # accept this form. Also, this should match the form that time2iso8601
        # produces.
        $value = $7 ? "$1-$2-$3T$4:$5:$6$7" : "$1-$2-$3T$4:$5:$6";
		$value .= $8 if $8;
    }
    else
    {
        $RPC::XML::ERROR = "${class}::new: Malformed data (" .
            (defined($value) ? $value : '<undef>') .
            ') passed as dateTime.iso8601';
        return;
    }

    bless \$value, $class;
}

###############################################################################
#
#   Package:        RPC::XML::nil
#
#   Description:    The "nil" type-class extension
#
###############################################################################
package RPC::XML::nil;

use strict;
use base 'RPC::XML::simple_type';

# no value need be passed to this method
sub new
{
    my $class = shift;
    my $value = undef;

    unless ($RPC::XML::ALLOW_NIL)
    {
        $RPC::XML::ERROR = "${class}::new: \$RPC::XML::ALLOW_NIL must be set" .
            'for RPC::XML::nil objects to be supported';
        return;
    }

    bless \$value, $class;
}

# Stringification and serialsation are trivial..
sub as_string
{
    '<nil/>';
}

sub serialize
{
    my ($self, $fh) = @_;

    print $fh $self->as_string; # In case someone sub-classes this
}

###############################################################################
#
#   Package:        RPC::XML::array
#
#   Description:    This class encapsulates the array data type. Each element
#                   within the array should be one of the datatype classes.
#
###############################################################################
package RPC::XML::array;

use strict;
use base 'RPC::XML::datatype';

use Scalar::Util qw(blessed reftype);

# The constructor for this class mainly needs to sanity-check the value data
sub new
{
    my ($class, @args) = @_;

    # Special-case time: If the args-list has exactly two elements, and the
    # first element is "from" and the second element is an array-ref (or a
    # type derived from), then copy the ref's contents into @args.
    if ((2 == @args) && ($args[0] eq 'from') && (reftype($args[1]) eq 'ARRAY'))
    {
        @args = @{$args[1]};
    }

    # Ensure that each argument passed in is itself one of the data-type
    # class instances.
    bless [ RPC::XML::smart_encode(@args) ], $class;
}

# This became more complex once it was shown that there may be a need to fetch
# the value while preserving the underlying objects.
sub value
{
    my $self = shift;
    my $no_recurse = shift || 0;
    my $ret;

    if ($no_recurse)
    {
        $ret = [ @$self ];
    }
    else
    {
        $ret = [ map { $_->value } @$self ];
    }

    $ret;
}

sub as_string
{
    my $self = shift;

    join('',
         '<array><data>',
         (map { ('<value>', $_->as_string(), '</value>') } (@$self)),
         '</data></array>');
}

# Serialization for arrays is not as straight-forward as it is for simple
# types. One or more of the elements may be a base64 object, which has a
# non-trivial serialize() method. Thus, rather than just sending the data from
# as_string down the pipe, instead call serialize() recursively on all of the
# elements.
sub serialize
{
    my ($self, $fh) = @_;

    print $fh '<array><data>';
    for (@$self)
    {
        print $fh '<value>';
        $_->serialize($fh);
        print $fh '</value>';
    }
    print $fh '</data></array>';
}

# Length calculation starts to get messy here, due to recursion
sub length
{
    my $self = shift;

    # Start with the constant components in the text
    my $len = 28; # That the <array><data></data></array> part
    for (@$self) { $len += (15 + $_->length) } # 15 is for <value></value>

    $len;
}

###############################################################################
#
#   Package:        RPC::XML::struct
#
#   Description:    This is the "struct" data class. The struct is like Perl's
#                   hash, with the constraint that all values are instances
#                   of the datatype classes.
#
###############################################################################
package RPC::XML::struct;

use strict;
use base 'RPC::XML::datatype';

use Scalar::Util qw(blessed reftype);

# The constructor for this class mainly needs to sanity-check the value data
sub new
{
    my $class = shift;
    my %args = (ref($_[0]) and reftype($_[0]) eq 'HASH') ? %{$_[0]} : @_;

    # RT 41063: If all the values are datatype objects, either they came in
    # that way or we've already laundered them through smart_encode(). If there
    # is even one that isn't, then we have to pass the whole mess to be
    # encoded.
    my $ref =
        (grep(! (blessed($_) && $_->isa('RPC::XML::datatype')), values %args))
            ? RPC::XML::smart_encode(\%args) : \%args;

    bless $ref, $class;
}

# This became more complex once it was shown that there may be a need to fetch
# the value while preserving the underlying objects.
sub value
{
    my $self = shift;
    my $no_recurse = shift || 0;
    my %value;

    if ($no_recurse)
    {
        %value = map { $_, $self->{$_} } (keys %$self);
    }
    else
    {
        %value = map { $_, $self->{$_}->value } (keys %$self);
    }

    \%value;
}

sub as_string
{
    my $self = shift;
    my $key;

    join('',
         '<struct>',
         (map {
             ($key = $_) =~ s/$RPC::XML::xmlre/$RPC::XML::xmlmap{$1}/ge;
             ("<member><name>$key</name><value>",
              $self->{$_}->as_string,
              '</value></member>')
         } (keys %$self)),
         '</struct>');
}

# As with the array type, serialization here isn't cut and dried, since one or
# more values may be base64.
sub serialize
{
    my ($self, $fh) = @_;
    my $key;

    print $fh '<struct>';
    for (keys %$self)
    {
        ($key = $_) =~ s/$RPC::XML::xmlre/$RPC::XML::xmlmap{$1}/ge;
        RPC::XML::utf8_downgrade($key);
        print $fh "<member><name>$key</name><value>";
        $self->{$_}->serialize($fh);
        print $fh '</value></member>';
    }
    print $fh '</struct>';
}

# Length calculation is a real pain here. But not as bad as base64 promises
sub length
{
    my $self = shift;

    my $len = 17; # <struct></struct>
    for my $key (keys %$self)
    {
        $len += 45; # For all the constant XML presence
        $len += $self->{$key}->length;
        RPC::XML::utf8_downgrade($key);
        $len += length($key);
    }

    $len;
}

###############################################################################
#
#   Package:        RPC::XML::base64
#
#   Description:    This is the base64-encoding type. Plain data is passed in,
#                   plain data is returned. Plain is always returned. All the
#                   encoding/decoding is done behind the scenes.
#
###############################################################################
package RPC::XML::base64;

use strict;
use base 'RPC::XML::datatype';

use Scalar::Util 'reftype';

sub new
{
    require MIME::Base64;
    my ($class, $value, $encoded) = @_;

    my $self = {};

    $RPC::XML::ERROR = '';

    $self->{encoded} = $encoded ? 1 : 0; # Is this already Base-64?
    $self->{inmem}   = 0;                # To signal in-memory vs. filehandle

    # First, determine if the call sent actual data, a reference to actual
    # data, or an open filehandle.
    if (ref($value) and reftype($value) eq 'GLOB')
    {
        # This is a seekable filehandle (or acceptable substitute thereof).
        # This assignment increments the ref-count, and prevents destruction
        # in other scopes.
        binmode $value;
        $self->{value_fh} = $value;
        $self->{fh_pos}   = tell($value);
    }
    else
    {
        # Not a filehandle. Might be a scalar ref, but other than that it's
        # in-memory data.
        $self->{inmem}++;
        $self->{value} = ref($value) ? $$value : ($value || '');
        # We want in-memory data to always be in the clear, to reduce the tests
        # needed in value(), below.
        if ($self->{encoded})
        {
            local($^W) = 0; # Disable warnings in case the data is underpadded
            $self->{value} = MIME::Base64::decode_base64($self->{value});
            $self->{encoded} = 0;
        }
    }

    bless $self, $class;
}

sub value
{
    my $self      = shift;
    my $as_base64 = (defined $_[0] and $_[0]) ? 1 : 0;

    # There are six cases here, based on whether or not the data exists in
    # Base-64 or clear form, and whether the data is in-memory or needs to be
    # read from a filehandle.
    if ($self->{inmem})
    {
        # This is simplified into two cases (rather than four) since we always
        # keep in-memory data as cleartext
        return $as_base64 ?
            MIME::Base64::encode_base64($self->{value}, '') : $self->{value};
    }
    else
    {
        # This is trickier with filehandle-based data, since we chose not to
        # change the state of the data. Thus, the behavior is dependant not
        # only on $as_base64, but also on $self->{encoded}. This is why we
        # took pains to explicitly set $as_base64 to either 0 or 1, rather than
        # just accept whatever non-false value the caller sent. It makes this
        # first test possible.
        my ($accum, $pos, $res);
        $accum = '';

        $self->{fh_pos} = tell($self->{value_fh});
        seek($self->{value_fh}, 0, 0);
        if ($as_base64 == $self->{encoded})
        {
            $pos = 0;
            while ($res = read($self->{value_fh}, $accum, 1024, $pos))
            {
                $pos += $res;
            }
        }
        else
        {
            if ($as_base64)
            {
                # We're reading cleartext and converting it to Base-64. Read in
                # multiples of 57 bytes for best Base-64 calculation. The
                # choice of 60 for the multiple is purely arbitrary.
                $res = '';
                while (read($self->{value_fh}, $res, 60*57))
                {
                    $accum .= MIME::Base64::encode_base64($res, '');
                }
            }
            else
            {
                # Reading Base-64 and converting it back to cleartext. If the
                # Base-64 data doesn't have any line-breaks, no telling how
                # much memory this will eat up.
                local($^W) = 0; # Disable padding-length warnings
                $pos = $self->{value_fh};
                while (defined($res = <$pos>))
                {
                    $accum .= MIME::Base64::decode_base64($res);
                }
            }
        }
        seek($self->{value_fh}, $self->{fh_pos}, 0);

        return $accum;
    }
}

# The value needs to be encoded before being output
sub as_string
{
    my $self = shift;

    '<base64>' . $self->value('encoded') . '</base64>';
}

# If it weren't for Tellme and their damnable WAV files, and ViAir and their
# half-baked XML-RPC server, I wouldn't have to do any of this...
#
# (On the plus side, at least here I don't have to worry about encodings...)
sub serialize
{
    my ($self, $fh) = @_;

    # If the data is in-memory, just call as_string and pass it down the pipe
    if ($self->{inmem})
    {
        print $fh $self->as_string;
    }
    else
    {
        # If it's a filehandle, at least we take comfort in knowing that we
        # always want Base-64 at this level.
        my $buf = '';
        $self->{fh_pos} = tell($self->{value_fh});
        seek($self->{value_fh}, 0, 0);
        print $fh '<base64>';
        if ($self->{encoded})
        {
            # Easy-- just use read() to send it down in palatably-sized chunks
            while (read($self->{value_fh}, $buf, 4096))
            {
                print $fh $buf;
            }
        }
        else
        {
            # This actually requires work. As with value(), the 60*57 is based
            # on ideal Base-64 chunks, with the 60 part being arbitrary.
            while (read($self->{value_fh}, $buf, 60*57))
            {
                print $fh &MIME::Base64::encode_base64($buf, '');
            }
        }
        print $fh '</base64>';
        seek($self->{value_fh}, $self->{fh_pos}, 0);
    }
}

# This promises to be a big enough pain that I seriously considered opening
# an anon-temp file (one that's unlinked for security, and survives only as
# long as the FH is open) and passing that to serialize just to -s on the FH.
# But I'll do this the "right" way instead...
sub length
{
    my $self = shift;

    # Start with the constant bits
    my $len = 17; # <base64></base64>

    if ($self->{inmem})
    {
        # If it's in-memory, it's cleartext. Size the encoded version
        $len += length(MIME::Base64::encode_base64($self->{value}, ''));
    }
    else
    {
        if ($self->{encoded})
        {
            # We're lucky, it's already encoded in the file, and -s will do
            $len += -s $self->{value_fh};
        }
        else
        {
            # Oh bugger. We have to encode it.
            my $buf = '';
            my $cnt = 0;

            $self->{fh_pos} = tell($self->{value_fh});
            seek($self->{value_fh}, 0, 0);
            while ($cnt = read($self->{value_fh}, $buf, 60*57))
            {
                $len += length(MIME::Base64::encode_base64($buf, ''));
            }
            seek($self->{value_fh}, $self->{fh_pos}, 0);
        }
    }

    $len;
}

# This allows writing the decoded data to an arbitrary file. It's useful when
# an application has gotten a RPC::XML::base64 object back from a request, and
# knows that it needs to go straight to a file without being completely read
# into memory, first.
sub to_file
{
    my ($self, $file) = @_;

    my ($fh, $buf, $do_close, $count) = (undef, '', 0, 0);

    if (ref $file and retype($file) eq 'GLOB')
    {
        $fh = $file;
    }
    else
    {
        require Symbol;
        $fh = Symbol::gensym();
        unless (open($fh, '>', $file))
        {
            $RPC::XML::ERROR = $!;
            return -1;
        }
        binmode $fh;
        $do_close++;
    }

    # If all the data is in-memory, then we know that it's clear, and we
    # don't have to jump through hoops in moving it to the filehandle.
    if ($self->{inmem})
    {
        print $fh $self->{value};
        $count = CORE::length($self->{value});
    }
    else
    {
        # Filehandle-to-filehandle transfer.

        # Now determine if the data can be copied over directly, or if we have
        # to decode it along the way.
        $self->{fh_pos} = tell($self->{value_fh});
        seek($self->{value_fh}, 0, 0);
        if ($self->{encoded})
        {
            # As with the caveat in value(), if the base-64 data doesn't have
            # any line-breaks, no telling how much memory this will eat up.
            local($^W) = 0; # Disable padding-length warnings
            my $tmp_fh = $self->{value_fh};
            while (defined($_ = <$tmp_fh>))
            {
                $buf = MIME::Base64::decode_base64($_);
                print $fh $buf;
                $count += CORE::length($buf);
            }
        }
        else
        {
            my $size;
            while ($size = read($self->{value_fh}, $buf, 4096))
            {
                print $fh $buf;
                $count += $size;
            }
        }
        seek($self->{value_fh}, $self->{fh_pos}, 0);
    }

    close($fh) if $do_close;
    return $count;
}

###############################################################################
#
#   Package:        RPC::XML::fault
#
#   Description:    This is the class that encapsulates the data for a RPC
#                   fault-response. Like the others, it takes the relevant
#                   information and maintains it internally. This is put
#                   at the end of the datum types, though it isn't really a
#                   data type in the sense that it cannot be passed in to a
#                   request. But it is separated so as to better generalize
#                   responses.
#
###############################################################################
package RPC::XML::fault;

use strict;
use base 'RPC::XML::struct';

use Scalar::Util 'blessed';

# For our new(), we only need to ensure that we have the two required members
sub new
{
    my $class = shift;
    my @args = @_;

    my ($self, %args);

    $RPC::XML::ERROR = '';
    if (blessed $args[0] and $args[0]->isa('RPC::XML::struct'))
    {
        # Take the keys and values from the struct object as our own
        %args = %{$args[0]->value('shallow')};
    }
    elsif (@args == 2)
    {
        # This is a special convenience-case to make simple new() calls clearer
        %args = (faultCode   => RPC::XML::int->new($args[0]),
                 faultString => RPC::XML::string->new($args[1]));
    }
    else
    {
        %args = @args;
    }

    unless ($args{faultCode} and $args{faultString})
    {
        $class = ref($class) || $class;
        $RPC::XML::ERROR = "${class}::new: Missing required struct fields";
        return;
    }
    if (scalar(keys %args) > 2)
    {
        $class = ref($class) || $class;
        $RPC::XML::ERROR = "${class}::new: Extra struct fields not allowed";
        return;
    }

    $self = $class->SUPER::new(%args);
}

# This only differs from the display of a struct in that it has some extra
# wrapped around it. Let the superclass as_string method do most of the work.
sub as_string
{
    my $self = shift;

    '<fault><value>' . $self->SUPER::as_string . '</value></fault>';
}

# Again, only differs from struct in that it has some extra wrapped around it.
sub serialize
{
    my ($self, $fh) = @_;

    print $fh '<fault><value>';
    $self->SUPER::serialize($fh);
    print $fh '</value></fault>';
}

# Because of the slight diff above, length() has to be different from struct
sub length
{
    my $self = shift;

    $self->SUPER::length + 30; # For constant XML content
}

# Convenience methods:
sub code   { $_[0]->{faultCode}->value   }
sub string { $_[0]->{faultString}->value }

# This is the only one to override this method, for obvious reasons
sub is_fault { 1 }

###############################################################################
#
#   Package:        RPC::XML::request
#
#   Description:    This is the class that encapsulates the data for a RPC
#                   request. It takes the relevant information and maintains
#                   it internally until asked to stringify. Only then is the
#                   XML generated, encoding checked, etc. This allows for
#                   late-selection of <methodCall> or <methodCallSet> as a
#                   containing tag.
#
#                   This class really only needs a constructor and a method
#                   to stringify.
#
###############################################################################
package RPC::XML::request;

use strict;

use Scalar::Util 'blessed';

###############################################################################
#
#   Sub Name:       new
#
#   Description:    Creating a new request object, in this (reference) case,
#                   means checking the list of arguments for sanity and
#                   packaging it up for later use.
#
#   Arguments:      NAME      IN/OUT  TYPE      DESCRIPTION
#                   $class    in      scalar    Class/ref to bless into
#                   @argz     in      list      The exact disposition of the
#                                                 arguments is based on the
#                                                 type of the various elements
#
#   Returns:        Success:    object ref
#                   Failure:    undef, error in $RPC::XML::ERROR
#
###############################################################################
sub new
{
    my $class = shift;
    my @argz = @_;

    my ($self, $name);

    $class = ref($class) || $class;
    $RPC::XML::ERROR = '';

    unless (@argz)
    {
        $RPC::XML::ERROR = 'RPC::XML::request::new: At least a method name ' .
            'must be specified';
        return;
    }

    if (blessed $argz[0] and $argz[0]->isa('RPC::XML::request'))
    {
        # Maybe this will be a clone operation
    }
    else
    {
        # This is the method name to be called
        $name = shift(@argz);
        # All the remaining args must be data.
        @argz = RPC::XML::smart_encode(@argz);
        $self = { args => [ @argz ], name => $name };
        bless $self, $class;
    }

    $self;
}

# Accessor methods
sub name       { shift->{name}       }
sub args       { shift->{args} || [] }

###############################################################################
#
#   Sub Name:       as_string
#
#   Description:    This is a fair bit more complex than the simple as_string
#                   methods for the datatypes. Express the invoking object as
#                   a well-formed XML document.
#
#   Arguments:      NAME      IN/OUT  TYPE      DESCRIPTION
#                   $self     in      ref       Invoking object
#                   $indent   in      scalar    Indention level for output
#
#   Returns:        Success:    text
#                   Failure:    undef
#
###############################################################################
sub as_string
{
    my $self   = shift;

    my $text;

    $RPC::XML::ERROR = '';

    $text = qq(<?xml version="1.0" encoding="$RPC::XML::ENCODING"?>);

    $text .= "<methodCall><methodName>$self->{name}</methodName><params>";
    for (@{$self->{args}})
    {
        $text .= '<param><value>' . $_->as_string . '</value></param>';
    }
    $text .= '</params></methodCall>';

    $text;
}

# The difference between stringifying and serializing a request is much like
# the difference was for structs and arrays. The boilerplate is the same, but
# the destination is different in a sensitive way.
sub serialize
{
    my ($self, $fh) = @_;
    my $name = $self->{name};
    RPC::XML::utf8_downgrade($name);

    print $fh qq(<?xml version="1.0" encoding="$RPC::XML::ENCODING"?>);

    print $fh "<methodCall><methodName>$name</methodName><params>";
    for (@{$self->{args}})
    {
        print $fh '<param><value>';
        $_->serialize($fh);
        print $fh '</value></param>';
    }
    print $fh '</params></methodCall>';
}

# Compared to base64, length-calculation here is pretty easy, much like struct
sub length
{
    my $self = shift;

    my $len = 100 + length($RPC::XML::ENCODING); # All the constant XML present
    $len += length($self->{name});

    for (@{$self->{args}})
    {
        $len += 30; # Constant XML
        $len += $_->length;
    }

    $len;
}

###############################################################################
#
#   Package:        RPC::XML::response
#
#   Description:    This is the class that encapsulates the data for a RPC
#                   response. As above, it takes the information and maintains
#                   it internally until asked to stringify. Only then is the
#                   XML generated, encoding checked, etc. This allows for
#                   late-selection of <methodResponse> or <methodResponseSet>
#                   as above.
#
###############################################################################
package RPC::XML::response;

use strict;

use Scalar::Util 'blessed';

###############################################################################
#
#   Sub Name:       new
#
#   Description:    Creating a new response object, in this (reference) case,
#                   means checking the outgoing parameter(s) for sanity.
#
#   Arguments:      NAME      IN/OUT  TYPE      DESCRIPTION
#                   $class    in      scalar    Class/ref to bless into
#                   @argz     in      list      The exact disposition of the
#                                                 arguments is based on the
#                                                 type of the various elements
#
#   Returns:        Success:    object ref
#                   Failure:    undef, error in $RPC::XML::ERROR
#
###############################################################################
sub new
{
    my $class = shift;
    my @argz = @_;

    my ($self, %extra, %attr);

    $class = ref($class) || $class;

    $RPC::XML::ERROR = '';
    if (! @argz)
    {
        $RPC::XML::ERROR = 'RPC::XML::response::new: One of a datatype, ' .
            'value or a fault object must be specified';
    }
    elsif (blessed $argz[0] and $argz[0]->isa('RPC::XML::response'))
    {
        # This will eventually be a clone-operation. For now, just return it
        $self = $argz[0];
    }
    elsif (@argz > 1)
    {
        $RPC::XML::ERROR = 'RPC::XML::response::new: Responses may take ' .
            'only one argument';
    }
    else
    {
        $argz[0] = RPC::XML::smart_encode($argz[0]);

        $self = { value => $argz[0] };
        bless $self, $class;
    }

    $self;
}

# Accessor/status methods
sub value      { $_[0]->{value} }
sub is_fault   { $_[0]->{value}->is_fault }

###############################################################################
#
#   Sub Name:       as_string
#
#   Description:    This is a fair bit more complex than the simple as_string
#                   methods for the datatypes. Express the invoking object as
#                   a well-formed XML document.
#
#   Arguments:      NAME      IN/OUT  TYPE      DESCRIPTION
#                   $self     in      ref       Invoking object
#                   $indent   in      scalar    Indention level for output
#
#   Returns:        Success:    text
#                   Failure:    undef
#
###############################################################################
sub as_string
{
    my $self   = shift;

    my $text;

    $RPC::XML::ERROR = '';

    $text = qq(<?xml version="1.0" encoding="$RPC::XML::ENCODING"?>);

    $text .= '<methodResponse>';
    if ($self->{value}->isa('RPC::XML::fault'))
    {
        $text .= $self->{value}->as_string;
    }
    else
    {
        $text .= '<params><param><value>' . $self->{value}->as_string .
            '</value></param></params>';
    }
    $text .= '</methodResponse>';

    $text;
}

# See the comment for serialize() above in RPC::XML::request
sub serialize
{
    my ($self, $fh) = @_;

    print $fh qq(<?xml version="1.0" encoding="$RPC::XML::ENCODING"?>);

    print $fh '<methodResponse>';
    if ($self->{value}->isa('RPC::XML::fault'))
    {
        # A fault lacks the params-boilerplate
        $self->{value}->serialize($fh);
    }
    else
    {
        print $fh '<params><param><value>';
        $self->{value}->serialize($fh);
        print $fh '</value></param></params>';
    }
    print $fh '</methodResponse>';
}

# Compared to base64, length-calculation here is pretty easy, much like struct
sub length
{
    my $self = shift;

    my $len = 66 + length($RPC::XML::ENCODING); # All the constant XML present

    # This boilerplate XML is only present when it is NOT a fault
    $len += 47 unless ($self->{value}->isa('RPC::XML::fault'));
    $len += $self->{value}->length;

    $len;
}

1;

__END__

=head1 NAME

RPC::XML - A set of classes for core data, message and XML handling

=head1 SYNOPSIS

    use RPC::XML;

    $req = RPC::XML::request->new('fetch_prime_factors',
                                  RPC::XML::int->new(985120528));
    ...
    $resp = RPC::XML::ParserFactory->new()->parse(STREAM);
    if (ref($resp))
    {
        return $resp->value->value;
    }
    else
    {
        die $resp;
    }

=head1 DESCRIPTION

The B<RPC::XML> package is an implementation of the B<XML-RPC> standard.

The package provides a set of classes for creating values to pass to the
constructors for requests and responses. These are lightweight objects, most
of which are implemented as tied scalars so as to associate specific type
information with the value. Classes are also provided for requests, responses,
faults (errors) and a parser based on the L<XML::Parser> package from CPAN.

This module does not actually provide any transport implementation or
server basis. For these, see L<RPC::XML::Client> and L<RPC::XML::Server>,
respectively.

=head1 EXPORTABLE FUNCTIONS

At present, three simple functions are available for import. They must be
explicitly imported as part of the C<use> statement, or with a direct call to
C<import>:

=over 4

=item time2iso8601([$time])

Convert the integer time value in C<$time> (which defaults to calling the
built-in C<time> if not present) to a ISO 8601 string in the UTC time
zone. This is a convenience function for occassions when the return value
needs to be of the B<dateTime.iso8601> type, but the value on hand is the
return from the C<time> built-in.

=item smart_encode(@args)

Converts the passed-in arguments to datatype objects. Any that are already
encoded as such are passed through unchanged. The routine is called recursively
on hash and array references. Note that this routine can only deduce a certain
degree of detail about the values passed. Boolean values will be wrongly
encoded as integers. Pretty much anything not specifically recognizable will
get encoded as a string object. Thus, for types such as C<fault>, the ISO
time value, base-64 data, etc., the program must still explicitly encode it.
However, this routine will hopefully simplify things a little bit for a
majority of the usage cases.

=back

In addition to these three, the following "helper" functions are also
available. They may be imported explicitly, or via a tag of C<:types>:

    RPC_BOOLEAN RPC_INT RPC_I4 RPC_I8 RPC_DOUBLE
    RPC_DATETIME_ISO8601 RPC_BASE64 RPC_STRING RPC_NIL

Each creates a data object of the appropriate type from a single value
(or, in the case of B<RPC_NIL>, from no value). They are merely short-
hand for calling the constructors of the data classes directly.

All of the above (helpers and the first three functions) may be imported via
the tag C<:all>.

=head1 CLASSES

The classes provided by this module are broken into two groups: I<datatype>
classes and I<message> classes.

=head2 Data Classes

The following data classes are provided by this library. Each of these provide
at least the set of methods below. Note that these classes are designed to
create throw-away objects. There is currently no mechanism for changing the
value stored within one of these object after the constructor returns. It is
assumed that a new object would be created, instead.

The common methods to all data classes are:

=over 4

=item new($value)

Constructor. The value passed in is the value to be encapsulated in the new
object.

=item value

Returns the value kept in the object. Processes recursively for C<array> and
C<struct> objects.

=item as_string

Returns the value as a XML-RPC fragment, with the proper tags, etc.

=item serialize($filehandle)

Send the stringified rendition of the data to the given file handle. This
allows messages with arbitrarily-large Base-64 data within them to be sent
without having to hold the entire message within process memory.

=item length

Returns the length, in bytes, of the object when serialized into XML. This is
used by the client and server classes to calculate message length.

=item type

Returns the type of data being stored in an object. The type matches the
XML-RPC specification, so the normalized form C<datetime_iso8601> comes back
as C<dateTime.iso8601>.

=item is_fault

All types except the fault class return false for this. This is to allow
consistent testing of return values for fault status, without checking for a
hash reference with specific keys defined.

=back

The classes themselves are:

=over 4

=item RPC::XML::int

Creates an integer value. Constructor expects the integer value as an
argument.

=item RPC::XML::i4

This is like the C<int> class. Note that services written in strictly-typed
languages such as C, C++ or Java may consider the C<i4> and C<int> types as
distinct and different.

=item RPC::XML::i8

This represents an 8-byte integer, and is not officially supported by the
XML-RPC specification. This has been added to accommodate services already
in use that have chosen to add this extension.

=item RPC::XML::double

Creates a floating-point value.

=item RPC::XML::string

Creates an arbitrary string. No special encoding is done to the string (aside
from XML document encoding, covered later) with the exception of the C<E<lt>>,
C<E<gt>> and C<&> characters, which are XML-escaped during object creation,
and then reverted when the C<value> method is called.

=item RPC::XML::boolean

Creates a boolean value. The value returned will always be either of B<1>
or B<0>, for true or false, respectively. When calling the constructor, the
program may specify any of: C<0>, C<no>, C<false>, C<1>, C<yes>, C<true>.

=item RPC::XML::datetime_iso8601

Creates an instance of the XML-RPC C<dateTime.iso8601> type. The specification
for ISO 8601 may be found elsewhere. No processing is done to the data.

=item RPC::XML::nil

Creates a C<nil> value. The value returned will always be B<undef>. No value
should be passed when calling the constructor.

Note that nil is an extension to B<XML-RPC>, which is not supported by
all implementations. B<$RPC::XML::ALLOW_NIL> must be set to a non-false
value before objects of this type can be constructed. See
L</GLOBAL VARIABLES>. If B<$RPC::XML::ALLOW_NIL> is set to a false value,
the parsers will not recognize the C<< <nil /> >> tag at all.

In practice, this type is only useful to denote the equivalent of a "void"
return value from a function. The type itself is not interchangeable with
any of the other data-types.

=item RPC::XML::base64

Creates an object that encapsulates a chunk of data that will be treated as
base-64 for transport purposes. The value may be passed in as either a string
or as a scalar reference. Additionally, a second (optional) parameter may be
passed, that if true identifies the data as already base-64 encoded. If so,
the data is decoded before storage. The C<value> method returns decoded data,
and the C<as_string> method encodes it before stringification.

Alternately, the constructor may be given an open filehandle argument instead
of direct data. When this is the case, the data is never read into memory in
its entirety, unless the C<value> or C<as_string> methods are called. This
allows the manipulation of arbitrarily-large Base-64-encoded data chunks. In
these cases, the flag (optional second argument) is still relevant, but the
data is not pre-decoded if it currently exists in an encoded form. It is only
decoded as needed. Note that the filehandle passed must be open for reading,
at least. It will not be written to, but it will be read from. The position
within the file will be preserved between operations.

Because of this, this class supports a special method called C<to_file>, that
takes one argument. The argument may be either an open, writable filehandle or
a string. If it is a string, C<to_file> will attempt to open it as a file and
write the I<decoded> data to it. If the argument is a an open filehandle, the
data will be written to it without any pre- or post-adjustment of the handle
position (nor will it be closed upon completion). This differs from the
C<serialize> method in that it always writes the decoded data (where the other
always writes encoded data), and in that the XML opening and closing tags are
not written. The return value of C<to_file> is the size of the data written
in bytes.

=item RPC::XML::array

Creates an array object. The constructor takes zero or more data-type
instances as arguments, which are inserted into the array in the order
specified. C<value> returns an array reference of native Perl types. If a
non-null value is passed as an argument to C<value()>, then the array
reference will contain datatype objects (a shallow rather than deep copy).

=item RPC::XML::struct

Creates a struct object, the analogy of a hash table in Perl. The keys are
ordinary strings, and the values must all be data-type objects. The C<value>
method returns a hash table reference, with native Perl types in the values.
Key order is not preserved. Key strings are now encoded for special XML
characters, so the use of such (C<E<lt>>, C<E<gt>>, etc.) should be
transparent to the user. If a non-null value is passed as an argument to
C<value()>, then the hash reference will contain the datatype objects rather
than native Perl data (a shallow vs. deep copy, as with the array type above).

When creating B<RPC::XML::struct> objects, there are two ways to pass the
content in for the new object: Either an existing hash reference may be passed,
or a series of key/value pairs may be passed. If a reference is passed, the
existing data is copied (the reference is not re-blessed), with the values
encoded into new objects as needed.

=item RPC::XML::fault

A fault object is a special case of the struct object that checks to ensure
that there are two keys, C<faultCode> and C<faultString>.

As a matter of convenience, since the contents of a B<RPC::XML::fault>
structure are specifically defined, the constructor may be called with exactly
two arguments, the first of which will be taken as the code, and the second
as the string. They will be converted to RPC::XML types automatically and
stored by the pre-defined key names.

Also as a matter of convenience, the fault class provides the following
accessor methods for directly retrieving the integer code and error string
from a fault object:

=over 4

=item code

=item string

=back

Both names should be self-explanatory. The values returned are Perl values,
not B<RPC::XML> class instances.

=back

=head2 Message Classes

The message classes are used both for constructing messages for outgoing
communication as well as representing the parsed contents of a received
message. Both implement the following methods:

=over 4

=item new

This is the constructor method for the two message classes. The response class
may have only a single value (as a response is currently limited to a single
return value), and requests may have as many arguments as appropriate. In both
cases, the arguments are passed to the exported C<smart_encode> routine
described earlier.

=item as_string

Returns the message object expressed as an XML document. The document will be
lacking in linebreaks and indention, as it is not targeted for human reading.

=item serialize($filehandle)

Serialize the message to the given file-handle. This avoids creating the entire
XML message within memory, which may be relevant if there is especially-large
Base-64 data within the message.

=item length

Returns the total size of the message in bytes, used by the client and server
classes to set the Content-Length header.

=back

The two message-object classes are:

=over 4

=item RPC::XML::request

This creates a request object. A request object expects the first argument to
be the name of the remote routine being called, and all remaining arguments
are the arguments to that routine. Request objects have the following methods
(besides C<new> and C<as_string>):

=over 4

=item name

The name of the remote routine that the request will call.

=item args

Returns a list reference with the arguments that will be passed. No arguments
will result in a reference to an empty list.

=back

=item RPC::XML::response

The response object is much like the request object in most ways. It may
take only one argument, as that is all the specification allows for in a
response. Responses have the following methods (in addition to C<new> and
C<as_string>):

=over 4

=item value

The value the response is returning. It will be a RPC::XML data-type.

=item is_fault

A boolean test whether or not the response is signalling a fault. This is
the same as taking the C<value> method return value and testing it, but is
provided for clarity and simplicity.

=back

=back

=head1 DIAGNOSTICS

All constructors (in all data classes) return C<undef> upon failure, with the
error message available in the package-global variable B<C<$RPC::XML::ERROR>>.

=head1 GLOBAL VARIABLES

The following global variables may be changed to control certain behavior of
the library. All variables listed below may be imported into the application
namespace when you C<use> B<RPC::XML>:

=over 4

=item $ENCODING

This variable controls the character-set encoding reported in outgoing XML
messages. It defaults to C<us-ascii>, but may be set to any value recognized
by XML parsers.

=item $FORCE_STRING_ENCODING

By default, C<smart_encode> uses heuristics to determine what encoding
is required for a data type. For example, C<123> would be encoded as C<int>,
where C<3.14> would be encoded as C<double>. In some situations it may be
handy to turn off all these heuristics, and force encoding of C<string> on
all data types encountered during encoding. Setting this flag to C<true>
will do just that.

Defaults to C<false>.

=item $ALLOW_NIL

By default, the XML-RPC C<nil> extension is not supported. Set this to a
non-false value to allow use of nil values. Data objects that are C<nil>
are represented as B<undef> by Perl. See L</"The nil Datatype">.

=back

=head1 CAVEATS

This began as a reference implementation in which clarity of process and
readability of the code took precedence over general efficiency. It is now
being maintained as production code, but may still have parts that could be
written more efficiently.

=head1 BUGS

Please report any bugs or feature requests to
C<bug-rpc-xml at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=RPC-XML>. I will be
notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 SUPPORT

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=RPC-XML>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/RPC-XML>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/RPC-XML>

=item * Search CPAN

L<http://search.cpan.org/dist/RPC-XML>

=item * Source code on GitHub

L<http://github.com/rjray/rpc-xml>

=back

=head1 COPYRIGHT & LICENSE

This file and the code within are copyright (c) 2009 by Randy J. Ray.

Copying and distribution are permitted under the terms of the Artistic
License 2.0 (L<http://www.opensource.org/licenses/artistic-license-2.0.php>) or
the GNU LGPL 2.1 (L<http://www.opensource.org/licenses/lgpl-2.1.php>).

=head1 CREDITS

The B<XML-RPC> standard is Copyright (c) 1998-2001, UserLand Software, Inc.
See L<http://www.xmlrpc.com> for more information about the B<XML-RPC>
specification.

=head1 SEE ALSO

L<RPC::XML::Client>, L<RPC::XML::Server>, L<RPC::XML::Parser>, L<XML::Parser>

=head1 AUTHOR

Randy J. Ray <rjray@blackperl.com>

=cut
