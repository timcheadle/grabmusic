#!/usr/bin/perl
#
# This program will connect to a UltraVox stream and get the music stream.
# It can save the music to a file, or play it with splay.
#
# It will not store partial songs (if you start or end in the
# middle of the song), or overwrite existing songs.

use strict;
use warnings;

use Cwd;
use File::Basename;
use IO::Socket;
use IO::Pipe;
use IO::Select;
use Getopt::Long qw(permute bundling);
use LWP::UserAgent;
use MP3::Info;
use MPEG::ID3v2Tag;
use Pod::Usage;

# Constants
#
my $CRLF = "\015\012";
my $AA_URL = 'http://broadband-albumart.streamops.aol.com/scan';


# Handle signals, remove partial files
#
sub shutdown {
  undef $playpipe if defined $playpipe;
  if(defined $outfile) {
    undef $outfile;
    unlink $filename; # remove partial file
  }
  exit;
}

$SIG{TERM} = \&shutdown;
$SIG{INT}  = \&shutdown;
$SIG{HUP}  = \&shutdown;
$SIG{QUIT} = \&shutdown;
$SIG{ABRT} = \&shutdown;
$SIG{SEGV} = \&shutdown;


# Command line options
#
my $dir       = cwd();
my $player    = 0;
my $recorder  = 0;
my $firstsong = 1;
my $verbose   = 0;
my $sortdir   = 0;
GetOptions(
    'p'   => \$player,
    'f'   => \$firstsong,
    'v+'  => \$verbose,
    's'   => \$sortdir,
    'd=s' => \$dir,
    'r'   => \$recorder
    'h'   => sub { pod2usage(1); },
) or pod2usage(1);

my $host      = shift @ARGV;
my $stream_id = shift @ARGV;

pod2usage('Invalid host') unless defined $host;
pod2usage('Invalid stream ID') unless defined $stream_id;


# Get host IP if necessary
#
my $ip = $host;
if($host !~ /^\d+\.\d+\.\d+\.\d+$/) {
    $ip = inet_ntoa(inet_aton($ip));
}


# Keep track of our output file and pipe globally so
# signal handlers can grab them
#
my $outfile;
my $playpipe;


# Handles client socket I/O
#
sub client_io {
    my $ip   = shift;
    my $strm = shift;

    my $recv_size  = $player ? 400 : 2048;
    my $buff_size  = 50000;
    my $failtime   = 0;
    my $recv_buf = '';

    # Keep track of song metadata
    my $metadata;

    # Keep an output file
    my $outfile;

    my $select = IO::Select->new();

    my($data, $socket, $sendata, $null, $msgclass, $msgtype, $SongLength);
    my($header, $sync, $qos, $msg, $len, $strm_data, $line, $SongId, $Serial);
    my($SongName, $AlbumName, $ArtistName, $MetaData, $Soon, $AlbumArt, $iTunesSong);

    # Open socket
    print "Opening socket\n" if $verbose;
    my $socket = IO::Socket::INET->new(
        PeerAddr => $ip,
        PeerPort => 80,
        Proto    => 'tcp',
        Timeout  => 20,
        Type     => SOCK_STREAM) || die "Could not open socket: $!";

    print "Socket opened\n" if $verbose;

    # Send HTTP command to get stream
    my $send_data = join($CRLF,
        "GET /stream/$strm HTTP/1.1",
        "Host: ultravox.aol.com",
        "User-Agent: ultravox/2.0",
        "Ultravox-transport-type: TCP",
        "Accept: */*",
    );
    $send_data .= $CRLF;
    $send_data .= $CRLF;
    print $socket $send_data;
    print "$send_data\n" if $verbose;

    # Read HTTP headers in response
    my $data;
    while($socket and length($recv_buf) < $buff_size) {
        $data = '';
        recv($socket, $data, $recv_size, 0);
        $recv_buf .= $data;
    }

    # Headers are followed by two CRLFs
    my ($header, $partial_buf)  = split(/\r\n\r\n/, $recv_buf);

    # Save header, partial buffer if we got it
    if (defined $header and $header ne '' and defined $temp and $temp ne '') {
        $recv_buf = $temp;
        print "$header\n" if $verbose;
    } else {
        exit 1;
    }

    # Continue filling our buffer with the content
    while($socket){
        $data = '';
        if(length($recv_buf) < $buff_size) {
            recv($socket, $data, $recv_size, 0);
            if($data ne '') {
                $recv_buf .= $data;
            }
        }

        # Get a frame of data
        my ($sync, $qos, $msg, $strm_data, $null) = unpack("aCnn/aC", $recv_buf);

        # If a complete frame then process it, else wait for more data.
        # a frame starts with a 'Z' and ends with a null.
        if (defined $sync and $sync eq 'Z' and defined $null and $null == 0) {
            # Remove the frame data
            $recv_buf = substr($recv_buf,length($strm_data)+7);
            $msgclass = $msg >> 12;

            # If metadata frame, the previous song ended
            if($msgclass == 0x3) {
                # Tidy up and finish writing the last song, if there was one
                if (defined $outfile) {
                    finish_song($outfile, $metadata);
                }

                # If we were playing a track, close the pipe
                if (defined $playpipe) {
                    $select->remove($playpipe);
                    $playpipe->close();
                }
                
                # Process new metadata
                $metadata = process_metadata_frame($strm_data);
                
                # Create a new output file
                my $filename = get_song_filename($metadata);
                $outfile = IO::File->("> $filename");

                # Create a new player if necessary
                if($player) {
                    $playpipe = IO::File->new("|mpg123 - >/dev/null 2>&1");
                    $playpipe->autoflush;
                    $select->add($playpipe);
                }

            # If this is real stream data, record and/or play it
            } elsif ($msgclass == 0x7) {
                # Record our output
                if (defined $outfile) {
                    print $outfile $strm_data;
                }

                # Play it if necessary
                if (defined $playpipe) {
                    $select->can_write();
                    print $playpipe $strm_data;
                }
            } 
        }
    }

	$socket->close();
}

# Process a metadata frame and return a hash
#
sub process_metadata_frame {
	my $frame = shift;

	my $xml = (unpack("nnna*", $strm_data))[3];

    my $metadata = {
        song        => map {&decode_html($_)} $MetaData =~ /\<name\>(.+)\<\/name\>/;
        album       => map {&decode_html($_)} $MetaData =~ /\<album\>(.+)\<\/album\>/;
        artist      => map {&decode_html($_)} $MetaData =~ /\<artist\>(.+)\<\/artist\>/;
        album_art   => map {&decode_html($_)} $MetaData =~ /\<album_art\>(.+)\<\/album_art\>/;
        coming_soon => map {&decode_html($_)} $MetaData =~ /\<soon\>(.+)\<\/soon/;
        song_id     => map {&decode_html($_)} $MetaData =~ /\<SongId\>(.+)\<\/SongId/;
        length      => map {&decode_html($_)} $MetaData =~ /\<length\>(.+)\<\/length\>/;
        itunes_id   => map {&decode_html($_)} $MetaData =~ /\<itunes_song_id\>(.+)\<\/itunes_song_id\>/;
        serial_num  => map {&decode_html($_)} $MetaData =~ /\<Serial\>(.+)\<\/Serial/;
    }

    $metadata{length} /= 1000;  # length is in msec

    return $metadata;
}

sub print_metadata {
    my $metadata = shift;

    my $length_min = int($metadata{length} / 60);
    my $length_sec = $metadata{length} % 60;

    print "time        = " . scalar(localtime(time())) . "\n";
    print "artist      = $metadata{artist}\n";
    print "album       = $metadata{album}\n";
    print "song        = $metadata{song}\n";
    print "length      = $length_min:$length_sec\n";
    print "coming soon = $metadata{coming_soon}\n";
    print "album art   = $metadata{album_art}\n";
    print "song id     = $metadata{song_id}\n";
    print "iTunes id   = $metadata{itunes_id}\n";
    print "serial      = $metadata{serial}\n";
    print "\n";
}

                    if($recorder) {
                        $ArtistName =~ s/\//-/g;
                        $AlbumName  =~ s/\//-/g;
                        $SongName   =~ s/\//-/g;
                        $ArtistName =~ s/%(..)/pack("c",hex($1))/ge;
                        $AlbumName  =~ s/%(..)/pack("c",hex($1))/ge;
                        $SongName   =~ s/%(..)/pack("c",hex($1))/ge;
                        $ArtistName =~ s/^\s*(\S.*\S)\s*$/$1/g;
                        $AlbumName  =~ s/^\s*(\S.*\S)\s*$/$1/g;
                        $SongName   =~ s/^\s*(\S.*\S)\s*$/$1/g;
                        if ($sortdir) {
                            $filename = "$dir/$ArtistName/$AlbumName/$ArtistName - $AlbumName - $SongName.mp3";
                        } else {
                            $filename = "$dir/$ArtistName - $AlbumName - $SongName.mp3";
                        }
                        #if($firstsong or -e $filename or defined $ignore{$ArtistName}) {
                        #if($firstsong or defined $ignore{$ArtistName}) {
                        if($firstsong) {
                            print "Skipping recording \"$filename\"\n" if $verbose;
                            $firstsong = 0;
                        } else {
                            &check_dirs($filename);
                            if(-e $filename) {
                                unlink $filename;
                            }
                            $outfile = new IO::File "> $filename";
                            my $tag = MPEG::ID3v2Tag->new();
                            $tag->add_frame("TIT2", $SongName);
                            $tag->add_frame("TALB", $AlbumName);
                            $tag->add_frame("TPE1", $ArtistName);
                            $tag->add_frame("TCOM", $strm);
                            $tag->add_frame("TLEN", $SongLength * 1000) if $SongLength =~ /^\d+$/;
                            $tag->set_padding_size(256);
                            my($aafile,$ua,$req,$dat);
                            print $outfile $tag->as_string() if defined $tag and defined $outfile;
                            if($AlbumArt ne '') {
                                if ($sortdir) {
                                    $aafile = "$dir/$ArtistName/$AlbumName/$ArtistName - $AlbumName.jpg";
                                } else {
                                    $aafile = "$dir/$ArtistName - $AlbumName.jpg";
                                }
                                if(not -e $aafile) {
                                    $ua = LWP::UserAgent->new(timeout => 5);
                                    $req = new HTTP::Request('GET', "$aaurl/$AlbumArt");
                                    $dat = $ua->request($req);
                                    if($dat->is_success) {
                                        open OUT, ">$aafile";
                                        print OUT $dat->content;
                                        close OUT;
                                        print "Got Album Art\n" if $verbose;
                                    }else{
                                        print "Failed to get Album Art\n" if $verbose;
                                    }
                                    undef $dat;
                                }
                            }
                            }
                        }


sub check_dirs {
  my $filepath = shift;
  if(substr($filepath,0,1) ne '/') {
    $filepath = "$dir/$filepath";
  }
  $filepath =~ s/\/\//\//g;
  my @dirlist = split /\//, $filepath;
  pop @dirlist;
  my $list = '';
  my($item);
  for $item (@dirlist) {
    next if $item eq '';
    $list .= "/$item";
    if(! -d $list) {
print "Making $list\n";
      mkdir $list;
    }
  }
}


sub decode_html {
    my $txt = shift;
    $txt =~ s/&apos;/'/g;
    $txt =~ s/&quot;/"/g;
    $txt =~ s/&amp;/&/g;
    $txt =~ s/&gt;/>/g;
    $txt =~ s/&lt;/</g;
    return $txt;
}


__END__

=pod

=head1 NAME

grabmusic.pl - Ultravox Streaming Client

=head1 SYNOPSIS

 grabmusic.pl [OPTIONS] <host> <stream_id>

 Options:
    -p           Play stream using mpg123
    -v           Verbose output
    -s           Create organized output directory by artist, album
    -d <dir>     Directory to save output
    -r           Record stream
    -f           Record the partial first song (default: no)
    -h           Show this help message

=head1 AUTHOR

Tim Cheadle (tim@fourspace.com)

=cut 
