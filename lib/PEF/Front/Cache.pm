package PEF::Front::Cache;
use strict;
use warnings;
use Cache::FastMmap;
use PEF::Front::Config;
use Time::Duration::Parse;
use Time::HiRes 'time';
use Data::Dumper;

use base 'Exporter';
our @EXPORT = qw{
  get_cache
  remove_cache_key
  set_cache
  make_cache_key_from_req
};

my $cache;
my $dumper;

BEGIN {
	# empty grep means there's no config loaded - some statical
	# analyzing tools can break
	if (grep { /AppFrontConfig\.pm$/ } keys %INC) {
		$cache = Cache::FastMmap->new(
			share_file     => cfg_cache_file,
			cache_size     => cfg_cache_size,
			empty_on_exit  => 0,
			unlink_on_exit => 0,
			expire_time    => 0,
			init_file      => 1
		) or die "Can't create cache: $!";
	}
    $dumper = Data::Dumper->new([]);
	$dumper->Indent(0);
	$dumper->Pair(":");
	$dumper->Useqq(1);
	$dumper->Terse(1);
	$dumper->Deepcopy(1);
	$dumper->Sortkeys(1);
}

sub get_cache {
	my $key = $_[0];
	my $res = $cache->get($key);
	if ($res) {
		if ($res->[0] < time) {
			$cache->remove($key);
			return;
		}
		return $res->[1];
	} else {
		return;
	}
}

sub set_cache {
	my ($key, $obj, $expires) = @_;
	my $seconds = parse_duration($expires) || 60;
	$cache->set($key, [$seconds + time, $obj]);
}

sub remove_cache_key {
	my $key = $_[0];
	$cache->remove($key);
}

sub make_cache_key_from_req {
    my ($req, $cache_attr_key) = @_;
    my @keys = ref $cache_attr_key eq 'ARRAY'
        ? @$cache_attr_key
        : ($cache_attr_key);
    my %values = map { exists $req->{$_} ? ($_ => $req->{$_}) : () } @keys;
    $dumper->Values([\%values]);
    return $dumper->Dump;
}

1;
