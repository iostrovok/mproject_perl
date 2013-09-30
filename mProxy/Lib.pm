package Proxy::Lib;


use strict;
use warnings;
use utf8;

use IO::Socket;
use IO::Socket::INET;

sub set_socket {
    my $self = shift;

    return 1 if $self->{SOCK};

    $self->{COUNTER} = 0;

    $self->{SOCK} = IO::Socket::INET->new(
        PeerAddr => $self->{host},
        PeerPort => $self->{port},
        Proto => 'tcp'
    ) or die "Can't bind : $@\n";

    die "Can't bind : $@\n" unless $self->{SOCK};
    return 1;
}

sub send_action {
    my ( $self, $act, $id ) = @_;

    my $line = $self->send_line(
        $self->{version},
        $act,
        $id,
    );

    $self->to_socket( $line );
}

sub to_socket {
    my ( $self, $line ) = @_;
    $self->{DEBUG} && say $line;
    my $SOCK = $self->{SOCK};
    print $SOCK $line  . chr(0);
}

sub send_line {
    my ( $self, $ver, $act, $id, $data ) = @_;

    $data ||= {};

    my $line = join( '#',
                set_len_act ( $ver ),
                set_len_act ( $act ),
                set_len_act ( $id ),
                $self->{JSON}->encode($data),
            );
    utf8::encode $line;
    return $line;
}


sub set_len_act {
    my ( $self, $line ) = @_;
    my $l = length $line;
    return $line if $l == 10;
    return substr( $line, 0, 10 ) if $l > 10;
    return $line . substr( ' ' x 10, 0, 10 - $l );
}

1;
