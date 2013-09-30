package Proxy::Event;

# $Id:$

use strict;
use warnings;

use strict;
use warnings;
use utf8;

use List::Util qw/ first /;
use JSON::XS;
use Digest::MD5 qw(md5 md5_hex md5_base64);
use IO::Socket;
use Getopt::Long;
binmode STDOUT, ":utf8";

local $| = 1;

use AnyEvent;
use AnyEvent::Handle;

use Data::Dumper;

use constant LAST_SEND_KEEPALIVE_TIME => 1200;	# Second
use constant MUST_STOP_TIME => 5;	# Second

use constant ACTION_SEND	=> 'send';
use constant ACTION_CLEAN	=> 'clean';
use constant ACTION_PING	=> 'ping';

my $SOCK;
my $JSON = JSON::XS->new() or die "Can't bind : $@\n"; $JSON->utf8(0);
my $COUNTER = 0;

################################ INTERFACE SUBS ################################
sub new {
	my $class = shift;

    my $self = bless {
		host			=> undef,
		port			=> undef,
		io				=> undef,
		ping_timer		=> undef,
		keepalive_timer	=> undef,
		connect_timer	=> undef,
		worker_timer	=> [],
		read_list		=> undef,
		id => md5_hex( rand() . $$ . time ),
		version => 1,
		@_,
	}, $class;

	$self->{name_ready} = AnyEvent->condvar;
	$self->my_connect();

    return $self;
}

sub send {
	my $self = shift;
	my $data = shift;
	my $line = $self->send_line( $self->{version}, ACTION_SEND, $data );
	send_socket( $line );
}

sub clean {
	my $self = shift;

	$self->{read_list} = [];
	my $line = $self->send_line( $self->{version}, ACTION_CLEAN );
}

sub read {
	my $self = shift;
	my $id = shift;

	return @{$self->{read_list}} unless @{$self->{read_list}};

	return shift @{$self->{read_list}} unless $id;

	my $d = first { $_->{uniq_id} eq  $id } @{$self->{read_list}};
	@{$self->{read_list}} = map { $_->{uniq_id} ne  $id }  @{$self->{read_list}};
}



################################ INNER SUBS ################################

sub start {
	my $self = shift;
	$self->{name_ready}->recv;
}

sub my_connect {
    my ( $self ) = @_;

	$self->{connect_timer} = undef;

    # используем AnyEvent::Handle в качестве абстракции над сокетом для более удобной работы
    $self->{io} = new AnyEvent::Handle (
		keepalive		=> 0,
        connect			=> [ $self->{host}, $self->{port} ],
		autocork		=> 1,
        # регистрируем колбэки на случай разрыва соединения и ошибки
        on_error		=> sub {$self->on_error(@_)},
        on_disconnect	=> sub { $self->on_disconnect(@_) },
		on_connect		=> sub { $self->on_connect(@_) },
		on_eof			=> sub { $self->on_eof(@_) },
    );
}

sub _my_write {
	my $self = shift;
	my @work = @_;
	return unless $self->{io};

	eval {
		foreach my $t ( @work ) {
			next unless $t;
			$self->{io}->push_write( $t );
		}
	};
	if ( $@ ) { warn($@); }
}


sub on_connect {
	my $self = shift;

	my ( $handle, $host, $port, $retry ) = @_;

    # регистрируем колбэк, который будет вызван после того, как из сокета можно будет прочитать 6 байт - заголовок FLAP
    $self->{io}->push_read( line => sub { $self->on_read_data(@_) } );

	# устанавливаем таймер, вызывающий колбэк каждые 2 минуты "for connected check"
	$self->{keepalive_timer} = AnyEvent->timer(
			after		=> LAST_SEND_KEEPALIVE_TIME,
			interval	=> LAST_SEND_KEEPALIVE_TIME,
			cb			=> sub { $self->send_keepalive }
		);
}

sub send_keepalive {
    my ($self) = @_;
	$self->my_write( send_line( 1, ACTION_PING ) );
}

# колбэк, вызываемый при получении данных
sub on_read_data {
    my ($self, $io, $data) = @_;

    # вновь ждем сообщение
    $io->push_read( line => sub { $self->on_read_data(@_) });

    # мы получили данные, теперь можно создавать OC::ICQ::FLAP, используя заранее сохраненный номер канала
	#push ( @{$self->{read_list}}, $data );

	$data = eval { $JSON->decode($data) };

	if ( UNIVERSAL::isa( $data, 'HASH') && $data->{uniq_id} ) {
		$data->{prioritet} ||= 1;
		@{$self->{read_list}} = sort { $b->{prioritet} <=> $a->{prioritet} }  ( @{$self->{read_list}}, $data );
	}

	# вновь ждем сообщение
    $io->push_read( line => sub { $self->on_read_data(@_) });
}


sub on_error {
	my $self = shift;
	print 'ON_ERROR: '. Dumper([@_]);

	if ( $self->{io} ) {

	}
	$self->{io} = undef;
	$self->{keepalive_timer} = undef;

	# устанавливаем таймер, вызывающий колбэк каждые 2 минуты
	$self->{connect_timer} = AnyEvent->timer(
		after => int(5 * rand()), interval => 10, cb => sub { $self->my_connect }
	);
}

sub on_disconnect {
	my $self = shift;
	$self->on_error( @_ );
}

sub on_eof {
	my $self = shift;
	$self->on_error( @_ );
}


sub _check_std_param {
	my ( $ver, $act, $data ) = @_;

	return 1 unless $ver == 1; # We now support first version only
	return 2 unless $act eq 'clean' || $act eq 'send'; # We now support first version only
	return 3 unless ref $data eq 'HASH' && $data->{host}; # We now support first version only

	return ( 0, $ver, $act, $data );
}

sub uniq_id { join '.', ++$COUNTER, time, $_[0]->{id}; }

sub send_line {
	my $self = shift;

	my ( $ver, $act, $data ) = @_;

	$data ||= {};

	$data->{uniq_id} ||= $self->uniq_id();
	$data->{timeout} = 100 unless int( $data->{timeout} || 0 ) > 0;

	my $line = join( '#',
				set_len_act ( $ver ),
				set_len_act ( $act ),
				$JSON->encode($data),
			);
	utf8::encode $line;
	$self->_my_write( $line . chr(0) );

	return $data->{uniq_id};
}

sub set_len_act {
	my ( $line ) = @_;
	my $l = length $line;
	return $line if $l == 10;
	return substr( $line, 0, 10 ) if $l > 10;
	return $line . substr( '          ', 0, 10 - $l );
}


1;
