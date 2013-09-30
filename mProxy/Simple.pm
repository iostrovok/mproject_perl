package Proxy::Simple;

=head2
Single request throught socket
[
	{
		"use_mem_key": 1, // 1 or 0
		"mem_key": "", // uniq line for memcached storable
		"id":"asdasdasdsad" // uniq number for read data
		"timeout":12000,
	},
	{
		"protocol": {
			"protocol.type":"http",
			"protocol.port":"5000",
			"protocol.host":"127.0.0.1",
			"protocol.path":"/",
			"protocol.no_encode":"1",
			"protocol.how":"POST"
		},
		"data":"Большой набор странных чисел и букв",
	}
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
use IO::Socket;
use IO::Socket::INET;

my $DEBUG = 0;

local $| = 1;
binmode STDOUT, ":utf8";

use Data::Dumper;

use constant PROTOCOL_VERSION => '0.1';

use constant ACTION_SEND	  => 'send';
use constant ACTION_CLEAN	  => 'clean';
use constant ACTION_PING	  => 'ping';
use constant ACTION_STARTREAD => 'start_read';
use constant STD_READ_TIMEOUT => 2; # millisecond

my $SOCK;
my $JSON = JSON::XS->new() or die "Can't bind : $@\n"; $JSON->utf8(0);
my $COUNTER = 0;

################################ INTERFACE SUBS ################################
sub new {
	my $class = shift;

    my $self = bless {
		host			=> undef,
		port			=> undef,
		read_list		=> [],
		read_hash		=> {},
		sort_read_hash	=> [],
		id 				=> md5_hex( rand() . $$ . time ),
		version			=> 1,
		tail			=> '',
		time_start		=> 0,
		last_clean_id   => -1,
		read_timeout    => STD_READ_TIMEOUT,
		@_,
	}, $class;

	$self->reconnect();

    return $self;
}


sub start_read {
	my $self = shift;
	$self->send_action( ACTION_STARTREAD ) unless $self->{started_read};
	$self->{started_read} = 1;
}
sub clean { shift->stop_read() }
sub stop_read  {
	my $self = shift;
	$self->send_action( ACTION_CLEAN ) if $self->{session};
	undef $self->{session};
}
sub start_session  {
	my ( $self, $sess_id, $session_time_out ) = @_;

	return if $sess_id && $sess_id eq $self->{session};

	$self->stop_read();
	$self->{session} = $sess_id || md5_hex( PROTOCOL_VERSION . rand() . $$ . time );
	$self->{counter_send} = 0;
	$self->{counter_read} = 0;
	$self->{sended} = {};
	$self->{started_read} = 0;
	$self->{session_time_out} = $session_time_out > 0 ? $session_time_out : -1;
	$self->{time_start} = Time::HiRes::time();
}

sub send_data {
	my ( $self, $how, $data, $is_last ) = @_;
	$data ||= {}; $how  ||= {};

	return 0 unless UNIVERSAL::isa( $data, 'HASH' ) && UNIVERSAL::isa( $how, 'HASH' );

	$self->start_session( $how->{session} ) if $how->{session};

	$self->{counter_send}++;
	$self->{session} ||= md5_hex( PROTOCOL_VERSION . rand() . $$ . time );
	$data ||= {};

	$data->{timeout}  = int( $data->{timeout} || 0 ) || 100;
	my $id = ++$COUNTER;

	if ( $how->{use_mem_key} ) {
		$data->{mem_key} = $how->{mem_key} ? $how->{mem_key} : md5_hex(create_mem_key($data));
	}

	$data->{data} = $JSON->encode($data->{data}) if $how->{to_json};

	my $line = $self->send_line( PROTOCOL_VERSION, ACTION_SEND, $id, $data );

	$self->to_socket( $line );

	$self->{sended}{$id} = { how => $how, data => $data, id => $id, error => 'wait', send_out => 0 };
	$self->start_read() if $is_last;

	return $id;
}

sub _read_socket {
	my ( $self, $id, $first ) = @_;

	$DEBUG && say "_read_socket: \$id: $id, \$first: $first";
	$DEBUG && say "_read_socket: 1";
	return if $self->{counter_send} == $self->{counter_read};
	$DEBUG && say "_read_socket: 2";
	return if $id && $id ~~ $self->{sended} && $self->{sended}{$id}{error} eq 'success';
	$DEBUG && say "_read_socket: 3";
	$self->start_read();

	eval {
		$DEBUG && say "_read_socket: 4";
		local $SIG{ALRM} = sub { die "timeout_error" };
		$DEBUG && say "_read_socket _get_timeout: ", $self->_get_timeout( $id );
		ualarm( $self->_get_timeout( $id ) ); # set timeount in milliseconds
		while ( my $data = <$SOCK> ) {
			$DEBUG && say "_read_socket: 5: ". $data;
			$data = eval { $JSON->decode($data) };

			$DEBUG && say "_read_socket 222-0: ", Dumper($data);

			next unless UNIVERSAL::isa( $data, 'HASH') && $data->{number} && UNIVERSAL::isa( $data->{result}, 'HASH');
			$DEBUG && say "_read_socket 222-1: $data->{number}";
			next unless my $num = $data->{number};
			$DEBUG && say "_read_socket 222-2: $data->{number}";
			next unless $num ~~ $self->{sended};

			$self->{sended}{$num}{result} = $data;
			$self->{sended}{$num}{error}  = 'success';

			$self->{counter_read}++;
			$DEBUG && say "_read_socket 333-1: $self->{counter_send} == $self->{counter_read}";
			last if $self->{counter_send} == $self->{counter_read};
			$DEBUG && say "_read_socket 333-2: $id && $id eq $num";
			last if $id && $id eq $num;
			last if $first;
		}

		ualarm(0);
	};

	if ( $@ ) {
		# my $error = $@ =~ /timeout_error/ ? 'timeout_error' : $@;
		# Nothing
	}
}

sub _get_timeout {
	my ( $self, $id ) = @_;

	my $max_timeout = 0;
	if ( $id && $self->{sended}{$id} ) {
		$max_timeout = $self->{sended}{$id}{how}{timeout};
	}
	else {
		$max_timeout = first { $_ > 0 } reverse sort map { $_->{how}{timeout}} values %{$self->{sended}};
	}

	$max_timeout ||= 0;

	$max_timeout = int ( $max_timeout + 1000 * ( $self->{time_start} - Time::HiRes::time ));
	$max_timeout = $self->{read_timeout} if $max_timeout <= 0;

	return 1000 * $max_timeout; # convert microseconds to milliseconds
}

sub read_all {
	my ( $self ) = @_;

	$self->_read_socket();
	$_->{send_out} = 1 foreach values %{$self->{sended}};
	return [ values %{$self->{sended}} ];
}

sub read {
	my ( $self, $id ) = @_;

	return undef unless $id && $id ~~ $self->{sended};

	return $self->{sended}{$id} unless $self->{sended}{$id}{error} eq 'wait';

	$self->_read_socket( $id );
	$self->{sended}{$id}{send_out} = 1;
	return $self->{sended}{$id};
}

sub fetch {
	my ( $self ) = @_;
	$self->_read_socket( 0, 'first' );
	my $out = first { $_->{send_out} == 1 } values %{$self->{sended}};
	return $out;
}

################################ INNER SUBS ################################

sub reconnect {
	my $self = shift;

	return if $SOCK;

	$COUNTER = 0;
	$SOCK = IO::Socket::INET->new(
		PeerAddr => $self->{host},
		PeerPort => $self->{port},
		Proto => 'tcp'
	) or die "Can't bind : $@\n";
}

sub send_action {
	my ( $self, $act ) = @_;

	return unless $self->{session};

	my $line = $self->send_line(
		PROTOCOL_VERSION,
		$act,
		++$COUNTER,
		{ session => $self->{session} },
	);

	$self->to_socket( $line );
}

sub to_socket {
	my ( $self, $line ) = @_;
	$DEBUG && say $line;
	print $SOCK $line  . chr(0);
}

sub send_line {
	my ( $self, $ver, $act, $id, $data ) = @_;

	$data ||= {};

	my $line = join( '#',
				set_len_act ( $ver ),
				set_len_act ( $act ),
				set_len_act ( $id ),
				$JSON->encode($data),
			);
	utf8::encode $line;
	return $line;
}

sub set_len_act {
	my ( $line ) = @_;
	my $l = length $line;
	return $line if $l == 10;
	return substr( $line, 0, 10 ) if $l > 10;
	return $line . substr( ' ' x 10, 0, 10 - $l );
}

sub create_mem_key {
	my $data = shift;

	my $line = '';
	unless ( ref $data ) {
		$line = $data;
	}
	elsif ( UNIVERSAL::isa( $data, 'HASH') ) {
		foreach ( sort keys %$data ) {
			$line .= $_ . create_mem_key($data->{$_});
		}
	}
	elsif( UNIVERSAL::isa( $data, 'ARRAY') ) {
		foreach ( sort @$data ) {
			$line .= create_mem_key($data->[$_]);
		}
	}

	return $line;
}

1;
