use bigint;
use LWP::UserAgent;
use JSON -support_by_pp;
use Config::IniFiles;
use POSIX qw(strftime);
use IO::Socket::INET;
use Quota;

# required for --log-master
STDOUT->autoflush(1);

$ENV{PERL_LWP_SSL_VERIFY_HOSTNAME}=0;

my $cfg = Config::IniFiles->new( -file => "/etc/uwsgi/local.ini" );

my $base_url = 'https://'.$cfg->val('uwsgi', 'api_domain').'/api/private';
my $ssl_key = $cfg->val('uwsgi', 'api_client_key_file');
my $ssl_cert = $cfg->val('uwsgi', 'api_client_cert_file');

my $root_dev = get_mountpoint('/');

my $timeout = 30;

sub collect_metrics {
	my ($uid, $net_json) = @_;
	collect_metrics_cpu($uid);
	collect_metrics_io($uid);
	collect_metrics_mem($uid);
	collect_metrics_mem_rss($uid);
	collect_metrics_mem_cache($uid);
	collect_metrics_quota($uid);
	if ($net_json) {
		collect_metrics_net($uid, $net_json);
	}
}

sub collect_metrics_cpu {
	my ($uid) = @_;
	open CGROUP,'/sys/fs/cgroup/'.$uid.'/cpuacct.usage';
	my $value = <CGROUP>;
	close CGROUP;	
	chomp $value;
	push_metric($uid, 'container.cpu', $value);
}

sub collect_metrics_mem {
        my ($uid) = @_;
        open CGROUP,'/sys/fs/cgroup/'.$uid.'/memory.usage_in_bytes';
        my $value = <CGROUP>;
        close CGROUP;
        chomp $value;
        push_metric($uid, 'container.mem', $value);
}

sub collect_metrics_mem_rss {
        my ($uid) = @_;
        open CGROUP,'/sys/fs/cgroup/'.$uid.'/memory.stat';
	my $found = '';
	while(<CGROUP>) {
        	my ($key, $value) = split /\s/;
		if ($key eq 'total_rss') {
			$found = $value;
			break;
		}
	}
        close CGROUP;
	return unless $found;
        chomp $found;
        push_metric($uid, 'container.mem.rss', $found);
}

sub collect_metrics_mem_cache {
        my ($uid) = @_;
        open CGROUP,'/sys/fs/cgroup/'.$uid.'/memory.stat';
        my $found = '';
        while(<CGROUP>) {
                my ($key, $value) = split /\s/;
                if ($key eq 'total_cache') {
                        $found = $value;
                        break;
                }
        }
        close CGROUP;
        return unless $found;
        chomp $found;
        push_metric($uid, 'container.mem.cache', $found);
}


sub collect_metrics_quota {
        my ($uid) = @_;
	my ($blocks) = Quota::query($root_dev, $uid);
        push_metric($uid, 'container.quota', Math::BigInt->new($blocks) * 1024);
}

sub collect_metrics_net {
	my ($uid, $tuntap) = @_;
	my $peers = $tuntap->{peers};
	foreach(@{$peers}) {
		if ($_->{uid} == $uid) {
			push_metric($uid, 'container.net.rx', $_->{rx});
			push_metric($uid, 'container.net.tx', $_->{tx});
			return;
		}
	}
}

sub collect_metrics_io {
	my ($uid) = @_;
	my $r = Math::BigInt->new('0');
	my $w = Math::BigInt->new('0');

	open CGROUP,'/sys/fs/cgroup/'.$uid.'/blkio.io_service_bytes';
	while(<CGROUP>) {
		chomp;
		my ($device, $type, $value) = split /\s+/;
		if ($type eq 'Read') {
			my $r0 = Math::BigInt->new($value);
			$r += $r0;
		}
		elsif ($type eq 'Write') {
			my $w0 = Math::BigInt->new($value);
			$w += $w0;
		}
	}
	close CGROUP;

	push_metric($uid, 'container.io.read', $r);
	push_metric($uid, 'container.io.write', $w);
}

for(;;) {
	my $ua = LWP::UserAgent->new;
	$ua->ssl_opts(
		SSL_key_file => $ssl_key,
		SSL_cert_file => $ssl_cert,
	);
	$ua->timeout($timeout);

	my $response =  $ua->get($base_url.'/containers/');

	if ($response->is_error or $response->code != 200 ) {
		print date().' oops: '.$response->code.' '.$response->message."\n";
		exit;
	}

	my $containers = decode_json($response->decoded_content);

	my $net_json = undef;
	# get json stats from the tuntap router
	my $s = IO::Socket::INET->new(PeerAddr => '127.0.0.1:5002');
	if ($s) {
		my $tuntap_json = '';
		for(;;) {
			$s->recv(my $buf, 8192);
			last unless $buf;
			$tuntap_json .= $buf;
		}
		$net_json = decode_json($tuntap_json);	
	}


	foreach(@{$containers}) {
		collect_metrics($_->{uid}, $net_json);
	}

	my $d_json = undef;
	# now collect domains metrics
	my $s = IO::Socket::INET->new(PeerAddr => '127.0.0.1:5003');
        if ($s) {
                my $domains_json = '';
                for(;;) {
                        $s->recv(my $buf, 8192);
                        last unless $buf;
                        $domains_json .= $buf;
                }
                $d_json = decode_json($domains_json);
        }
	foreach(@{$d_json->{subscriptions}}) {
		my $domain = $_->{key};
		my $nodes = $_->{nodes};
		foreach(@{$nodes}) {
			if ($_->{uid} > 30000) {
				push_domain_metric($_->{uid}, $domain, 'domain.net.rx', $_->{rx}); 
				push_domain_metric($_->{uid}, $domain, 'domain.net.tx', $_->{rx}); 
				push_domain_metric($_->{uid}, $domain, 'domain.hits', $_->{requests}); 
			}
		}
	}

	my $response =  $ua->get($base_url.'/serverfilemetadata/');

        if ($response->is_error or $response->code != 200 ) {
                print date().' oops: '.$response->code.' '.$response->message."\n";
                exit;
        }

        my $file_metadata = decode_json($response->decoded_content);
	foreach(@{$file_metadata}) {
		push_metadata_file($_);
	}

	# gather metrics every 5 minutes
	sleep(300);
}

sub date {
	return strftime "%Y-%m-%d %H:%M:%S", localtime;
}

sub push_metadata_file {
	my ($filename) = @_;

	my $ua = LWP::UserAgent->new;
        $ua->ssl_opts(
                SSL_key_file => $ssl_key,
                SSL_cert_file => $ssl_cert,
        );
        $ua->timeout($timeout);

	open my $fh, '<',$filename;
	return unless $fh;
	my $value = do { local $/; <$fh> };
	close $fh;
        my $j = JSON->new;
        $j = $j->encode({file => $filename, value => $value });

        my $response =  $ua->post($base_url.'/serverfilemetadata/', Content => $j);

        if ($response->is_error or $response->code != 201 ) {
                print date().' oops for '.$path.'/'.$uid.': '.$response->code.' '.$response->message."\n";
        }
	
}

sub push_metric {
	my ($uid, $path, $value) = @_;

	my $ua = LWP::UserAgent->new;
        $ua->ssl_opts(
                SSL_key_file => $ssl_key,
                SSL_cert_file => $ssl_cert,
        );
        $ua->timeout($timeout);

	my $j = JSON->new;
	$j->allow_bignum(1);
	$j = $j->encode({unix => time, value => Math::BigInt->new($value)});

	my $response =  $ua->post($base_url.'/metrics/'.$path.'/'.$uid, Content => $j);

	if ($response->is_error or $response->code != 201 ) {
                print date().' oops for '.$path.'/'.$uid.': '.$response->code.' '.$response->message."\n";
        }
}

sub push_domain_metric {
        my ($uid, $domain, $path, $value) = @_;

        my $ua = LWP::UserAgent->new;
        $ua->ssl_opts(
                SSL_key_file => $ssl_key,
                SSL_cert_file => $ssl_cert,
        );
        $ua->timeout($timeout);

        my $j = JSON->new;
        $j->allow_bignum(1);
        $j = $j->encode({domain => $domain, unix => time, value => Math::BigInt->new($value)});

        my $response =  $ua->post($base_url.'/metrics/'.$path.'/'.$uid, Content => $j);

        if ($response->is_error or $response->code != 201 ) {
                print date().' oops for '.$path.'/'.$uid.': '.$response->code.' '.$response->message."\n";
        }
}

sub get_mountpoint {
	my ($mountpoint) = @_;
	open MOUNTS,'/proc/self/mounts';
	while(<MOUNTS>) {
		my ($dev, $mp) = split /\s/;
		if ($mp eq $mountpoint) {
			if ($dev ne 'rootfs') {
				return $dev;
			}
		}
	}
	return '';
}
