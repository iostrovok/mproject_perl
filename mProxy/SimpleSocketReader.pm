package mProxy::SimpleSocketReader;

=head2
Single request throught socket
[
    {
        "use_mem_key": 1, // 1 or 0
        "mem_key": "", // uniq line for memcached storable
        "id":"asdasdasdsad" // uniq number for read data
        "timeout":12000,
    },
]
=cut

# $Id:$

use feature qw(say switch);

use strict;
use warnings;
use utf8;

use Time::HiRes qw [ time ualarm ];
use List::Util qw[ first ];
use JSON::XS;
use Digest::MD5 qw[ md5 md5_hex md5_base64 ];


use base qw[ Proxy::Lib ];

local $| = 1;
binmode STDOUT, ":utf8"; # for test

use Data::Dumper;

use constant PROTOCOL_VERSION  => '0.1';
use constant ACTION_SUB       => 'sub';

my $JSON = JSON::XS->new() or die "Can't bind : $@\n"; $JSON->utf8(0);


################################ INTERFACE SUBS ################################
sub new {
    my $class = shift;

    my $self = bless {
        host            => undef,
        port            => undef,
        id              => md5_hex( rand() . $$ . time ),
        version         => PROTOCOL_VERSION,
        tail            => '',
        time_start      => 0,
        key             => '',
        COUNTER         => 0,
        JSON            => $JSON,
        DEBUG           => 1,
        @_,
    }, $class;

    unless ( $self->{key} ) {
        $self->{error} = 'no setup "key" param';
        return $self;
    }

    $self->reconnect();

    return $self;
}


sub read {
    my ( $self, $timeout ) = @_;

    $timeout ||= 0;
    my $data;

    eval {
        my $SOCK = $self->{SOCK};
        $self->{DEBUG} && say "_read_socket: 4";
        local $SIG{ALRM} = sub { die "timeout_error" };
        $self->{DEBUG} && say "_read_socket _get_timeout: $timeout";
        ualarm( $timeout ) if $timeout > 0; # set timeount in milliseconds
        my $data = <$SOCK>;
        $self->{DEBUG} && say "_read_socket: 5: ". $data;
        ualarm(0);
        $data = $JSON->decode($data) if $data;
    };

    if ( $@ ) {
        return { error => $@ };
    }

    return $data if UNIVERSAL::isa( $data, 'HASH' );
    return { error => 'empty' };
}

################################ INNER SUBS ################################

sub reconnect {
    my $self = shift;

    return unless $self->set_socket;

    $self->subscribe();
}

sub subscribe  {
    my ( $self ) = @_;

    return unless $self->{key};
    $self->{tail} = '';
    $self->{counter_read} = 0;
    $self->{time_start} = Time::HiRes::time();

    my $line = $self->send_line(
        PROTOCOL_VERSION,
        ACTION_SUB,
        ++$self->{COUNTER},
        { key => $self->{key} },
    );

    $self->to_socket( $line );
}

1;
