package PEF::Front::Request;
use strict;
use warnings;
use JSON;
use Carp ();
use utf8;
use Encode;
use PEF::Front::Headers;
use PEF::Front::File;
use PEF::Front::Config;
use XML::Simple;
use URI;

sub new {
	my ($class, $env) = @_;
	Carp::croak(q{$env is required})
	  unless defined $env && ref ($env) eq 'HASH';
	my $self = bless {env => $env}, $class;
	$self->_parse;
	$self;
}
sub env              { $_[0]->{env} }
sub remote_ip        { $_[0]->{env}{REMOTE_ADDR} }
sub protocol         { $_[0]->{env}{SERVER_PROTOCOL} }
sub method           { $_[0]->{env}{REQUEST_METHOD} }
sub port             { $_[0]->{env}{SERVER_PORT} }
sub user             { $_[0]->{env}{REMOTE_USER} }
sub request_uri      { $_[0]->{env}{REQUEST_URI} }
sub path_info        { $_[0]->{env}{PATH_INFO} }
sub query_string     { $_[0]->{env}{QUERY_STRING} }
sub script_name      { $_[0]->{env}{SCRIPT_NAME} }
sub scheme           { $_[0]->{env}{'psgi.url_scheme'} }
sub uri              { URI->new($_[0]->base) }
sub secure           { $_[0]->scheme eq 'https' }
sub _input           { $_[0]->{env}{'psgi.input'} }
sub content_length   { $_[0]->{env}{CONTENT_LENGTH} }
sub content_type     { $_[0]->{env}{CONTENT_TYPE} }
sub raw_body         { $_[0]->{raw_body} }
sub content_encoding { $_[0]->headers->get_header("content_encoding") }
sub header           { $_[0]->headers->get_header($_[1]) }
sub referer          { $_[0]->headers->get_header("referer") }
sub user_agent       { $_[0]->headers->get_header("user_agent") }

sub logger {
	my $self = $_[0];
	cfg_logger($self);
	#$self->{env}{'psgix.logger'}
	#  || sub { $self->{env}{'psgi.errors'}->print($_[0]->{message}); }
}

sub _parse {
	my $self = $_[0];
	$self->_parse_query_params;
	$self->_parse_request_body if $self->method eq 'POST';
}

sub params {
	my $self = $_[0];
	return $self->{params} if exists $self->{params};
	my $q = $self->{query_params} || {};
	my $p = $self->{body_params}  || {};
	$self->{params} = {%$q, %$p};
}

sub path {
	my $self = $_[0];
	return $self->{path} if @_ == 1 and exists $self->{path};
	$self->{path} ||= decode_utf8($self->{env}{PATH_INFO} || '/');
	if (@_ == 2) {
		my $np = (utf8::is_utf8($_[1]) ? $_[1] : decode_utf8 $_[1]);
		if (not defined $np or $np =~ /^\s*$/) {
			$self->{path} = '/';
		} else {
			if (substr ($np, 0, 1) ne '/') {
				$self->{path} =
				  substr ($self->{path}, 0, rindex ($self->{path}, '/') + 1) . $np;
			} else {
				$self->{path} = $np;
			}
		}
	}
	return $self->{path};
}

sub note {
	my ($self, $key, $value) = @_;
	if (@_ == 3) {
		$self->{note}{$key} = $value;
	}
	if (exists $self->{note}{$key}) {
		$self->{note}{$key};
	} else {
		return;
	}
}

sub param {
	my ($self, $param, $value) = @_;
	return $self->params->{$param} if not defined $value;
	$self->params->{$param} = (utf8::is_utf8($value) ? $value : decode_utf8 $value);
}

sub hostname {
	my $self = $_[0];
	return $self->{hostname} if exists $self->{hostname};
	$self->{hostname} = $self->{env}{HTTP_HOST} || $self->{env}{SERVER_NAME};
	$self->{hostname} =~ s/:\d+//;
	$self->{hostname};
}

sub base {
	my $self = $_[0];
	return $self->{base} if exists $self->{base};
	$self->{base} =
	  $self->scheme . "://" . ($self->{env}{HTTP_HOST} || $self->{env}{SERVER_NAME}) . $self->request_uri;
	$self->{base};
}

sub cookies {
	my $self = $_[0];
	return {} unless $self->{env}{HTTP_COOKIE};
	return $self->{cookies} if exists $self->{cookies};
	my %results;
	my @pairs = grep m/=/, split "[;,] ?", $self->{env}{HTTP_COOKIE};
	for my $pair (@pairs) {
		$pair =~ s/^\s+//;
		$pair =~ s/\s+$//;
		my ($key, $value) =
		  map {
			tr/+/ /;
			s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
			decode_utf8 $_
		  } split ("=", $pair, 2);
		$results{$key} = $value;
	}
	$self->{cookies} = \%results;
}

sub _parse_urlencoded {
	my $query = $_[0];
	my $form  = {};
	my @pairs = split (/[&;]/, $query);
	foreach my $pair (@pairs) {
		my ($name, $value) =
		  map { tr/+/ /; s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg; $_ }
		  split (/=/, $pair, 2);
		eval { $form->{decode_utf8($name)} = decode_utf8 $value if defined $name and $name ne ''; };
	}
	return $form;
}

sub headers {
	my $self = shift;
	if (!defined $self->{headers}) {
		my $env = $self->{env};
		$self->{headers} = PEF::Front::HTTPHeaders->new(
			map {
				(my $field = decode_utf8 $_) =~ s/^HTTPS?_//;
				($field => decode_utf8 $env->{$_});
			  }
			  grep {
				/^HTTP/ || /^CONTENT/
			  } keys %$env
		);
	}
	$self->{headers};
}

sub _parse_query_params {
	my $self = $_[0];
	return {} if !$self->{env}{QUERY_STRING};
	return $self->{query_params} if exists $self->{query_params};
	$self->{query_params} = _parse_urlencoded($self->{env}{QUERY_STRING});
}

sub _parse_request_body {
	my $self = $_[0];
	my $ct   = $self->{env}{CONTENT_TYPE};
	my $cl   = $self->{env}{CONTENT_LENGTH};
	if (!$ct && !$cl) {
		return;
	}
	return $self->{body_params} if exists $self->{body_params};
	my $read_body_sub = sub {
		$self->{raw_body} = '';
		my $buffer;
		while ($cl && $self->_input->read($buffer, $cl)) {
			$self->{raw_body} .= $buffer;
			$cl -= length $buffer;
		}
	};
	if (index ($ct, 'application/x-www-form-urlencoded') == 0) {
		$read_body_sub->();
		$self->{body_params} = _parse_urlencoded($self->{raw_body});
	} elsif (index ($ct, 'application/json') == 0) {
		$read_body_sub->();
		my $from_json = $self->{raw_body};
		if (substr ($self->{raw_body}, 0, 2) eq '%7') {
			$from_json =~ tr/+/ /;
			$from_json =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
		}
		$self->{body_params} = eval { $from_json && decode_json $from_json } || {};
		return $self->{body_params};
	} elsif (index ($ct, 'application/xml') == 0) {
		$read_body_sub->();
		$self->{body_params} = eval { XMLin $self->{raw_body} } || {};
		return $self->{body_params};
	} elsif (index ($ct, 'multipart/form-data') == 0) {
		$self->_parse_multipart_form;
	}
	if (exists $self->{body_params}{json}) {
		my $form = eval { from_json $self->{body_params}{json} } || {};
		$self->{body_params} = {%{$self->{body_params}}, %$form};
	}
	return $self->{body_params};
}

sub _parse_multipart_form {
	my $self   = $_[0];
	my $buffer = '';
	my $input  = $self->_input;
	my $cl     = $self->{env}{CONTENT_LENGTH};
	my $ct     = $self->{env}{CONTENT_TYPE};
	$self->{body_params} = {};
	my $form = $self->{body_params};
	my ($boundary) = $ct =~ /boundary=\"?([^\";,]+)\"?/;
	return if not defined $boundary;
	my $start_boundary = "--" . $boundary . "\x0d\x0a";
	my $end_boundary   = "--" . $boundary . "--\x0d\x0a";
	my $chl            = 65536;
	my $lchnk          = 0;
	my $current_field;
	while (1) {
		my $chunk;
		my $start = index ($buffer, $start_boundary);
		$start = index ($buffer, $end_boundary) if $start == -1;
		$buffer .= $chunk if $start == -1 && $input->read($chunk, $chl);
		last if $buffer eq '';
		$start = index ($buffer, $start_boundary) if $start == -1;
		$start = index ($buffer, $end_boundary)   if $start == -1;
		my $field_sub = sub {
			if (   $buffer ne ''
				&& $buffer =~ /^Content-Disposition:/
				&& (my $body_start = index ($buffer, "\x0d\x0a\x0d\x0a")))
			{
				my $header = substr ($buffer, 0, $body_start);
				substr ($buffer, 0, $body_start + 4, '');
				my $next_start = index ($buffer, $start_boundary);
				$next_start = index ($buffer, $end_boundary) if $next_start == -1;
				my $current_value;
				if ($next_start >= 0) {
					$current_value = substr ($buffer, 0, $next_start - 2);
					substr ($buffer, 0, $next_start, '');
				} else {
					$current_value = '';
				}
				my ($name) = ($header =~ /name="?([^";\x0d\x0a]*)[";]?/);
				my ($file) = ($header =~ /filename="?([^";\x0d\x0a]*)[";\x0d\x0a]?/);
				my ($type) = ($header =~ /Content-Type:\s*(\S+)/);
				$name ||= '';
				if (defined ($file) && $file ne '') {
					($file) = ($file =~ /([^\/\\]*)$/);
					$file =~ s/^\s*//;
					$file =~ s/\s*$//;
					$file =~ s/^(\w+:+)+//;
					if ($file eq '' || substr ($file, 0, 1) eq '.') {
						$file = "unnamed_upload" . $file;
					}
					$current_field = decode_utf8($name);
					$form->{$current_field} = PEF::Front::File->new(
						filename => decode_utf8($file),
						size     => $cl,
						content_type => $type || 'application/octet-stream',
						(   exists ($form->{$current_field . '_id'})
							  && !ref ($form->{$current_field . '_id'})
							? (
								id => $self->remote_ip . "/" . $self->scheme . "/" . $self->hostname . "/" . $form->{$current_field . '_id'})
							: ()
						)
					);
					$current_field = $form->{$current_field};
					$current_field->append($current_value);
				} else {
					$current_field = decode_utf8($name);
					$form->{$current_field} = $current_value;
				}
				$current_field = undef if $next_start >= 0;
				return 1;
			}
			return;
		};
		if ($start >= 0) {
			last if (my $end = index ($buffer, $end_boundary)) == 0;
			my $be = $end == $start ? 2 : 0;
			if (    defined $current_field
				and ref $current_field eq 'PEF::Front::File'
				and $start > 1)
			{
				$current_field->append(substr ($buffer, 0, $start - 2));
				$current_field->finish;
				$current_field = undef;
				substr ($buffer, 0, $start + length ($start_boundary) + $be, '');
			} elsif (defined $current_field and $start > 1) {
				$form->{$current_field} .= substr ($buffer, 0, $start - 2);
				$current_field = undef;
				substr ($buffer, 0, $start + length ($start_boundary) + $be, '');
			}
			if (not $field_sub->()) {
				substr ($buffer, 0, $start + length ($start_boundary) + $be, '');
			}
		} else {
			my $store_chunk = $lchnk;
			if (length ($buffer) < $store_chunk + 256) {
				if (length ($buffer) > 512) {
					$store_chunk = length ($buffer) - 256;
				} else {
					$store_chunk = 0;
				}
			}
			if (defined $current_field and ref $current_field eq 'PEF::Front::File') {
				if ($store_chunk) {
					$current_field->append(substr ($buffer, 0, $store_chunk));
					substr ($buffer, 0, $store_chunk, '');
				}
			} elsif (defined $current_field) {
				if ($store_chunk) {
					$form->{$current_field} .= substr ($buffer, 0, $store_chunk);
					substr ($buffer, 0, $store_chunk, '');
				}
			} else {
				$field_sub->();
			}
		}
		$lchnk = length $buffer;
	}
	for my $k (keys %$form) {
		$form->{$k} = decode_utf8 $form->{$k} if not ref $form->{$k};
	}
	return $form;
}
1;
__END__

=head1 NAME

PEF::Front::Request - HTTP request object from PSGI env hash

=head1 SYNOPSIS

package My::Local::Test;

  sub test {
    my ($msg, $defaults) = @_;
    return {
        result    => "OK",
        data      => [1, 2],
        path_info => $defaults->{request}->path_info
    };
  }

=head1 DESCRIPTION

L<PEF::Front::Request> provides a consistent API for request objects across
PEF::Front framework.

=head1 CAVEAT

This module is intended to be used by web application developers only in rare circumstances.
Developers can receive an object of this type in "Local", "InFilter" and "OutFilter" handlers via hash "defaults". 

=head1 METHODS

Unless otherwise noted, all methods and attributes are B<read-only>,
and passing values to the method like an accessor doesn't work like
you expect it to.

=over 2

=item new

    PEF::Front::Request->new( $env );

Creates a new request object from supplied $env hash. Intended for internal use only.

=item env

Returns the shared PSGI environment hash reference. This is a
reference, so writing to this environment passes through during the
whole PSGI request/response cycle.

=item remote_ip

Returns the IP address of the client (C<REMOTE_ADDR>).

=item method

Contains the request method (C<GET>, C<POST>, C<HEAD>, etc).

=item protocol

Returns the protocol (HTTP/1.0 or HTTP/1.1) used for the current request.

=item request_uri

Returns the raw, undecoded request URI path. You probably do B<NOT>
want to use this to dispatch requests.

=item path_info

Returns B<PATH_INFO> in the environment. Use this to get the local
path for the requests.

=item path ( [$path] )

Similar to C<path_info> but can be changed during internal routing process. 
Decoded to utf8 perl internal representation.

=item query_string

Returns B<QUERY_STRING> in the environment. This is the undecoded
query string in the request URI.

=item script_name

Returns B<SCRIPT_NAME> in the environment. This is the absolute path
where your application is hosted. B<NOT TESTED>

=item scheme

Returns the scheme (C<http> or C<https>) of the request.

=item secure

Returns true or false, indicating whether the connection is secure (https).

=item uri

Returns an URI object for the current request. 

Every time this method is called it returns a new, cloned URI object.

=item logger

Returns (optional) C<psgix.logger> code reference. When it exists,
your application is supposed to send the log message to this logger,
using:

  $req->logger->({ level => 'debug', message => "This is a debug message" });

=item cookies

Returns a reference to a hash containing the cookies. Values are
strings that are sent by clients and are URI decoded.

If there are multiple cookies with the same name in the request, this
method will ignore the duplicates and return only the first value. If
that causes issues for you, you may have to use modules like
CGI::Simple::Cookie to parse C<<$request->header('Cookies')>> by
yourself.

=item params

Returns a hash reference containing (merged) GET
and POST parameters.

=item raw_body

Returns the request content in an undecoded byte string for POST requests.

=item base

Returns full URL string of current request.

=item user

Returns C<REMOTE_USER> if it's set.

=item headers

Returns an L<PEF::Front::HTTPHeaders> object containing the headers for the current request.

=item content_encoding

Shortcut to $req->headers->get_header("content_encoding").

=item content_length

Returns length of content.

=item content_type

Returns Content-Type header value.

=item header

Shortcut to $req->headers->get_header.

=item referer

Shortcut to $req->headers->get_header("referer").

=item user_agent

Shortcut to $req->headers->get_header("user_agent").

=item param($param, [$value])

Returns GET and POST parameters. This is an alternative method for accessing parameters in
$req->params. It B<does> allow setting or modifying query parameters.

=back

=head1 AUTHORS

PEF Secure

=head1 LICENSE

This library is free software; you can redistribute it and/or modify

it under the same terms as Perl itself.

=cut
