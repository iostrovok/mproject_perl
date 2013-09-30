#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use Data::Dumper;
use Getopt::Long;

binmode STDOUT, ":utf8";
use Time::HiRes qw [ time ualarm ];

use Proxy::SimpleSocketReader;

my ( $KEY, $DEBUG, $PORT, $HOST ) = ( '', 0, 0, '' );

my $result = GetOptions (
        "k|key=s" => \$KEY,
        "d|debug=i" => \$DEBUG,
        "p|port=i" => \$PORT,
        "h|host=s" =>\$HOST,
    );

print "\$KEY = $KEY, \$DEBUG = $DEBUG\n";

$KEY ||= 'test_line';
$PORT ||= 40005;
$HOST ||= '127.0.0.1';

my $Proxy = new Proxy::SimpleSocketReader( key => $KEY, DEBUG => $DEBUG, port => $PORT, host => $HOST );

while ( $Proxy->read ) {
    print Dumper( $_ );
}



__END__
