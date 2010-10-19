# Traffic shaper sub-class

# **** License ****
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2008 Vyatta, Inc.
# All Rights Reserved.
# **** End License ****

package Vyatta::Qos::ShaperClass;
use strict;
use warnings;

require Vyatta::Config;
use Vyatta::Qos::Match;
use Vyatta::Qos::Util qw/getDsfield getRate/;

use constant {
    AVGPKT  => 1024,    # Average packet size for RED calculations
    LATENCY => 250,     # Worstcase latency for RED (ms)
};

sub new {
    my ( $that, $config, $id ) = @_;
    my $class = ref($that) || $that;
    my $self = {};

    $self->{id} = $id;

    bless $self, $class;

    if ($config) {
        my $level = $config->setLevel();

        $self->{level}     = $level;
        $self->{_rate}     = $config->returnValue("bandwidth");
        $self->{_priority} = $config->returnValue("priority");
        $self->{_ceiling}  = $config->returnValue("ceiling");
        $self->{_burst}    = $config->returnValue("burst");
        $self->{_limit}    = $config->returnValue("queue-limit");
        $self->{_avgpkt}   = $config->returnValue("packet-length");
        $self->{_latency}  = $config->returnValue("latency");
	$self->{_quantum}  = $config->returnValue("quantum");

        $self->{dsmark} = getDsfield( $config->returnValue("set-dscp") );

        my @matches = _getMatch("$level match");
        $self->{_match} = \@matches;

	my @subclasses = $config->listNodes("class");
	my $qtype      = $config->returnValue("queue-type");
	
	if (@subclasses) {
	    die "can not set queue-type with sub-classes\n"
		if defined($qtype);

	    my @classes;
	    foreach my $id (@subclasses) {
		$config->setLevel("$level class $id");
		push @classes, $self->new($config, $id);
	    }
	    $self->{_class} = \@classes;
	} else {
	    $self->{_qdisc} = defined($qtype) ? $qtype : 'fair-queue';
	}
    }

    return $self;
}

sub _getMatch {
    my $level = shift;
    my @matches;
    my $config = new Vyatta::Config;

    foreach my $match ( $config->listNodes($level) ) {
        $config->setLevel("$level $match");
        push @matches, new Vyatta::Qos::Match($config);
    }
    return @matches;
}

sub _getPercentRate {
    my ( $rate, $speed ) = @_;
    return unless defined($rate);

    # Rate might be a percentage of speed
    if ( $rate =~ /%$/ ) {
        my $percent = substr( $rate, 0, length($rate) - 1 );
        if ( $percent < 0 || $percent > 100 ) {
            die "Invalid percentage bandwidth: $percent\n";
        }

        return ( $percent * $speed ) / 100.;
    } 

    return getRate($rate);
}

sub prioQdisc {
    my ( $self, $dev, $rate ) = @_;
    my $prio_id = 0x4000 + $self->{id};
    my $limit   = $self->{_limit};

    printf "handle %x: prio\n", $prio_id;

    if ($limit) {
        foreach my $i (qw/1 2 3/) {
            printf "qdisc add dev %s parent %x:%x pfifo limit %d\n",
              $dev, $prio_id, $i, $limit;
        }
    }
}

sub sfqQdisc {
    my ( $self, $dev, $rate ) = @_;

    print "sfq";
    print " limit $self->{_limit}" if ( $self->{_limit} );
    print "\n";
}

sub sfqValidate {
    my ( $self, $level ) = @_;
    my $limit = $self->{_limit};

    if ( defined $limit && $limit > 127 ) {
        print STDERR "Configuration error in: $level\n";
        die "queue limit must be between 1 and 127 for queue-type fair-queue\n";
    }
}

sub fifoQdisc {
    my ( $self, $dev, $rate ) = @_;

    print "pfifo";
    print " limit $self->{_limit}" if ( $self->{_limit} );
    print "\n";
}

# Red is has way to many configuration options
# make some assumptions to make this sane (based on LARTC)
#   average size = 1000 bytes
#   latency      = 100ms
#
#                       Bandwidth (bits/sec) * Latency (ms)
# Maximum Threshold = --------------------------------------
#   (bytes)                   8 bits/byte *  1000 ms/sec
#
# Minimum Threshold = Maximum Threshold / 3
# Avpkt = Average Packet Length
# Burst = ( 2 * MinThreshold + MaxThreshold) / ( 3 * Avpkt )
# Limit = 4 * MaxThreshold
#
# These are based on Sally Floyd's recommendations:
#  http://www.icir.org/floyd/REDparameters.txt
sub redQsize {
    my $bw = shift;

    return ( $bw * LATENCY ) / ( 8 * 1000 );
}

sub redQdisc {
    my ( $self, $dev, $rate ) = @_;
    my $qmax = ( defined $rate ) ? redQsize($rate) : ( 18 * AVGPKT );
    my $qmin = $qmax / 3;
    $qmin = AVGPKT if $qmin < AVGPKT;

    my $burst  = ( 2 * $qmin + $qmax ) / ( 3 * AVGPKT );
    my $limit  = $self->{_limit};
    my $qlimit = ( defined $limit ) ? ( $limit * AVGPKT ) : ( 4 * $qmax );

    printf "red limit %d min %d max %d avpkt %d", $qlimit, $qmin, $qmax, AVGPKT;
    printf " burst %d probability 0.1 bandwidth %s ecn\n", $burst, $rate;
}

# Check if the parameters for RED will work
sub redValidate {
    my ( $self, $level, $rate ) = @_;
    my $limit = $self->{_limit};	# packets
    my $thresh = redQsize($rate);	# bytes
    my $qmax  = POSIX::ceil($thresh / AVGPKT); # packets

    if ( defined($limit) && $limit < $qmax ) {
        print STDERR "Configuration error in: $level\n";
        printf STDERR
"The queue limit (%d) is too small, must be %d or more when using random-detect\n",
	    $limit, $qmax;
        exit 1;
    }

    if ( $qmax < 3 ) {
        my $minbw = ( 3 * AVGPKT * 8 ) / LATENCY;

        print STDERR "Configuration error in: $level\n";
	printf STDERR
"Random-detect queue type requires effective bandwidth of %d Kbit/sec or greater\n",
          $minbw;
	exit 1;
    }
}

my %qdiscOptions = (
    'priority'      => \&prioQdisc,
    'fair-queue'    => \&sfqQdisc,
    'random-detect' => \&redQdisc,
    'drop-tail'     => \&fifoQdisc,
);

my %qdiscValidate = (
    'fair-queue'    => \&sfqValidate,
    'random-detect' => \&redValidate,
);

# Check if the rate configured for the class is higher than the link
# speed, or if the rate exceeds the ceiling.
sub rateCheck {
    my ( $self, $ifspeed, $level ) = @_;

    my $rate = _getPercentRate( $self->{_rate}, $ifspeed );
    if ( $rate > $ifspeed ) {
        print STDERR "Configuration error in: $level\n";
        printf STDERR
          "The bandwidth reserved for this class (%dKbps) must be less than\n",
          $rate / 1000;
        printf STDERR "the bandwidth for the overall policy (%dKbps)\n",
          $ifspeed / 1000;
        exit 1;
    }

    my $ceil = _getPercentRate( $self->{_ceiling}, $ifspeed );
    if ( defined($ceil) && $ceil < $rate ) {
        print STDERR "Configuration error in: $level\n";
        printf STDERR
"The bandwidth ceiling for this class (%dKbps) must be greater or equal to\n",
          $ceil / 1000;
        printf STDERR "the reserved bandwidth for the class (%dKbps)\n",
          $rate / 1000;
        exit 1;
    }

    my $subclass = $self->{_class};
    if ($subclass) {
	my $rate = $self->{_rate};

	foreach my $class (@$subclass) {
	    $class->rateCheck($rate, "$level class $class->{id}");
	}
    } else {
	my $qtype = $self->{_qdisc};
	return unless $qtype;

	my $q = $qdiscValidate{$qtype};
	return unless $q;

	$q->( $self, $level, $rate );
    }
}

sub get_rate {
    my ( $self, $speed ) = @_;

    return _getPercentRate( $self->{_rate}, $speed );
}

# Generate tc commands for class
sub gen_class {
    my ( $self, $dev, $qdisc, $parent, $speed ) = @_;
    my $rate = _getPercentRate( $self->{_rate},    $speed );
    my $ceil = _getPercentRate( $self->{_ceiling}, $speed );

    printf "class add dev %s parent %x:1 classid %x:%x %s",
      $dev, $parent, $parent, $self->{id}, $qdisc;

    print " rate $rate"              if ($rate);
    print " ceil $ceil"              if ($ceil);
    print " burst $self->{_burst}"   if ( $self->{_burst} );
    print " prio $self->{_priority}" if ( $self->{_priority} );
    print " quantum $self->{_quantum}" if ( $self->{_quantum} );
    print "\n";
}

# Compute the maximum rate for the class
sub max_rate {
    my ($self, $speed) = @_;
    my $ceil = $self->{_ceiling};
    
    if ($ceil) {
	return _getPercentRate( $ceil, $speed );
    } else {
	return _getPercentRate( $self->{_rate}, $speed );
    }
}

# If this class has sub classes, generate those commands
# otherwise generate the qdisc parameters for the leaf
sub gen_leaf {
    my ( $self, $dev, $qdisc, $parent, $speed ) = @_;
    my $rate = max_rate($speed);

    my $subclass = $self->{_class};
    if ($subclass) {
	foreach my $class (@$subclass) {
	    $class->commands($dev, $qdisc, $self->{id}, $rate);
	}
    } else {
	my $qtype = $self->{_qdisc};
	my $q = $qdiscOptions{$qtype};
	die "Unknown queue-type $qtype\n"
	    unless $q;

	printf "qdisc add dev %s parent %x:%x ", $dev, $parent, $self->{id};
	$q->( $self, $dev, $rate );
    }
}

sub commands {
    my ($self, $dev, $qdisc, $parent, $rate) = @_;

    $self->gen_class( $dev, $qdisc, $parent, $rate );
    $self->gen_leaf( $dev, $qdisc, $parent, $rate );

    my $prio = 1;
    my $matches = $self->{_match};
    foreach my $match ( @$matches ) {
	$match->filter( $dev, $parent, $class->{id},
			$prio++, $class->{dsmark} );
    }
}

sub dsmarkClass {
    my ( $self, $parent, $dev ) = @_;

    printf "class change dev %s classid %x:%x dsmark",
      $dev, $parent, $self->{id};

    if ( $self->{dsmark} ) {
        print " mask 0 value $self->{dsmark}\n";
    }
    else {
        print " mask 0xff value 0\n";
    }
}

1;
