#!/usr/bin/perl

use strict;
use warnings;
use utf8;
use Data::Dumper;
use JSON::XS;
use Digest::MD5 qw(md5 md5_hex md5_base64);
use IO::Socket;
use Getopt::Long;
binmode STDOUT, ":utf8";
use Time::HiRes qw [ time ualarm ];

my $JSON = JSON::XS->new() or die "Can't bind : $@\n"; $JSON->utf8(0);

use Proxy::Simple;

my ( $ID, $is_send_message, $DEBUG) = ( 0, 0, 0 );

my $result = GetOptions (
        "n=i" => \$ID,
        "m=i" => \$is_send_message,
        "i=i" => \$DEBUG,
    );

print "\$ID = $ID, \$is_send_message = $is_send_message, \$DEBUG = $DEBUG\n";

my @Phrase = <DATA>;
chomp @Phrase;
@Phrase = grep { $_} @Phrase;


my @IDS = ();


my $data_file = "./online_request_data_inner.js";
open( FILE, $data_file ) or die "$!\n";
my $data = join('', <FILE>);
close FILE;

my $send_list = $JSON->decode( $data );

my $Proxy = new Proxy::Simple( port => '40005', host => '127.0.0.1' );

my $start_time = Time::HiRes::time();
$Proxy->start_session();

foreach ( @$send_list ) {
    print Dumper($_);
    next unless my $id = $Proxy->send_data( @{$_} );
    push @IDS, $id;
}

$Proxy->start_read();

#my $list = $Proxy->read_all();
#foreach ( @$list ) {  print_result('Read from ALL: ', $_ );  }

my %MESS;

foreach (  @IDS ) {
    $MESS{$_} = $Proxy->read($_);
}

my $stop_time = Time::HiRes::time();

foreach ( keys %MESS ) {
    print_result("Read by ID: id = $_ +++++++++++++++++\n", $MESS{$_} );
}

print "\$start_time = $start_time\n";
print "\$stop_time = $stop_time\n";
print "DELTA: ", ( $stop_time - $start_time), "\n";

#sleep(5);


sub print_result {
    my ( $title, $message ) = @_;

    unless ( $message ) {
        print "\n$title - MY RESULT: EMPTY======================================\n";
        return;
    }

    my $body = '';
    if ( exists $message->{result}{result}{body} ) {
        $message->{result}{result}{body} = "Length: ". length($message->{result}{result}{body} ) .", Content: ". substr($message->{result}{result}{body} , 0, 100);
    }

    print "\n$title - MY RESULT: ". Dumper($message);
    print "======================================\n";
}


__END__
