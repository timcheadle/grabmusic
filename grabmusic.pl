#!/usr/bin/perl
#
# This program will connect to a UltraVox stream and get the music stream.
# It can save the music to a file, or play it with splay.
#
# It will not store partial songs (if you start or end in the
# middle of the song), or overwrite existing songs.

use File::Basename;
use Cwd;
use IO::Socket;
use IO::Pipe;
use IO::Select;
use Getopt::Long;
use MP3::Info;
use MPEG::ID3v2Tag;
use LWP::UserAgent;
use strict;
use constant CRLF => "\015\012";

$SIG{TERM} = \&shutdown;
$SIG{INT}  = \&shutdown;
$SIG{HUP}  = \&shutdown;
$SIG{QUIT} = \&shutdown;
$SIG{ABRT} = \&shutdown;
$SIG{SEGV} = \&shutdown;

my $player    = 0;
my $recorder  = 0;
my $firstsong = 1;
my $verbose   = 0;
my $dir       = cwd();
my $sortdir   = 0;
Getopt::Long::Configure('permute','bundling');
GetOptions('h'  => \&printhelp,
           'p'  => \$player,
           'v+' => \$verbose,
	   's'  => \$sortdir,
           'd=s'  => \$dir,
           'r'  => \$recorder
          );
my $host = shift @ARGV;
my $strm = shift @ARGV;
my $ip   = $host;
if(not defined $host or not defined $strm){
  print "\n";
  print "Invalid host\n" if not defined $host;
  print "Invalid stream id\n" if not defined $strm;
  &printhelp;
}
my $aaurl = 'http://broadband-albumart.streamops.aol.com/scan';
my (@temp,$temp,$outfile,$playpipe,$filename,%ignore);
if($host !~ /^\d+\.\d+\.\d+\.\d+$/) {
  (undef,undef,undef,undef,@temp) = gethostbyname($host);
  @temp = map {inet_ntoa($_)} @temp;
  $ip = $temp[0];
}
&config;
&send_packets($ip, $strm);
exit;

sub printhelp {
  my $progname = (fileparse($0))[0];
  print "\n";
  if(defined $_){
    print "Invalid option: $_\n";
  }
  print "Usage: $progname -r|-p [-h] host streamID\n";
  print "  Options: -r   Tells program to record song to a file.\n";
  print "           -p   Tells program to play song via splay.\n";
  print "           -d   Which directory to save files int, defaults to\n";
  print "                current working directory.\n";
  print "           -s   Save files in ArtistName/AlbumName/ directories\n";
  print "           -v   Verbose: Prints song information.\n";
  print "           -h   Displays this help screen.\n";
  exit;
}

sub send_packets {
  my $ip         = shift;
  my $strm       = shift;;
  my $recv_size  = 2048;
  my $buff_size  = 50000;
  my $failtime   = 0;
  my $recvbuffer = '';
  my $select     = IO::Select->new();
  my($data, $socket, $sendata, $null, $msgclass, $msgtype, $SongLength);
  my($header, $sync, $qos, $msg, $len, $strmdata, $line, $SongId, $Serial);
  my($SongName, $AlbumName, $ArtistName, $MetaData, $Soon, $AlbumArt);
  print "Opening socket\n" if $verbose > 1;
  $recv_size = 400 if($player);
  $socket = IO::Socket::INET->new(PeerAddr => $ip,
                                  PeerPort => 80,
                                  Proto    => 'tcp',
                                  Timeout  => 20,
                                  Type     => SOCK_STREAM) || die "$!";
  print "Opened socket\n" if $verbose > 1;
  $sendata = "GET /stream/$strm HTTP/1.1" . CRLF .
             "Host: ultravox.aol.com" . CRLF .
             "User-Agent: ultravox/2.0" . CRLF .
             "Ultravox-transport-type: TCP" . CRLF .
             "Accept: */*" . CRLF . CRLF;
  print $socket $sendata;
  print "$sendata\n" if $verbose > 1;
  while($socket and length($recvbuffer) < $buff_size) {
    recv($socket, $data, $recv_size, 0);
    $recvbuffer .= $data;
  }
  ($header, $temp) = split /\r\n\r\n/, $recvbuffer;
  if(defined $header and $header ne '' and defined $temp and $temp ne '') {
    $recvbuffer = $temp;
    print "$header\n" if $verbose > 1;
  } else {
    exit 1;
  }
  while($socket){
    # receive data
    $data = '';
    if(length($recvbuffer) < $buff_size) {
      recv($socket, $data, $recv_size, 0);
      if($data ne '') {
        $recvbuffer .= $data;
      }
    }
    # get a frame of data
    ($sync,$qos,$msg,$strmdata,$null) = unpack("aCnn/aC", $recvbuffer);
    # if a complete frame then process it, else wait for more data.
    # a frame starts with a 'Z' and ends with a null.
    if(defined $sync and $sync eq 'Z' and defined $null and $null == 0) {
      $recvbuffer = substr($recvbuffer,length($strmdata)+7);
      $msgclass = $msg >> 12;
      #$msgtype  = $msg & 0x0fff;
      # if metadata
      if($msgclass >= 0x3 and $msgclass <= 0x6) {
        #($MetaID,$MetaSpan,$MetaIndex,$MetaData) = unpack("nnna*", $strmdata);
        ($MetaData) = (unpack("nnna*", $strmdata))[3];
        # if song metadata
        if($msgclass == 0x3) {
          if(defined $outfile) {
            $outfile->close;
            set_mp3tag($filename, substr($SongName,0,30), substr($ArtistName,0,30),
                                  substr($AlbumName,0,30), '', $strm, '');
          }
          if(defined $playpipe) {
            $select->remove($playpipe);
            $playpipe->close();
          }
          ($SongName)   = map {&txtdecode($_)} $MetaData =~ /\<SongName\>(.+)\<\/SongName/;
          ($AlbumName)  = map {&txtdecode($_)} $MetaData =~ /\<AlbumName\>(.+)\<\/AlbumName/;
          ($ArtistName) = map {&txtdecode($_)} $MetaData =~ /\<ArtistName\>(.+)\<\/ArtistName/;
          ($AlbumArt)   = map {&txtdecode($_)} $MetaData =~ /\<AlbumArt\>(.+)\<\/AlbumArt/;
          if($verbose) {
            ($Soon)       = map {&txtdecode($_)} $MetaData =~ /\<Soon\>(.+)\<\/Soon/;
#            ($SongId)     = map {&txtdecode($_)} $MetaData =~ /\<SongId\>(.+)\<\/SongId/;
#            ($SongLength) = map {&txtdecode($_)} $MetaData =~ /\<SongLength\>(.+)\<\/SongLength/;
#            ($Serial)     = map {&txtdecode($_)} $MetaData =~ /\<Serial\>(.+)\<\/Serial/;
	    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
	    print "Time       = $mon/$mday/$year $hour:$min:$sec\n"; 
            print "ArtistName = $ArtistName\n";
            print "AlbumName  = $AlbumName\n";
            print "SongName   = $SongName\n";
            print "Soon       = $Soon\n";
            print "AlbumArt   = $AlbumArt\n";
#            print "SongId     = $SongId\n";
#            print "SongLength = $SongLength\n";
#            print "Serial     = $Serial\n";
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
if(-e $filename) { unlink $filename; }
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
          if($player) {
            $playpipe = new IO::File "|splay -M >/dev/null 2>&1";
            $playpipe->autoflush;
            $select->add($playpipe);
          }
        }elsif($msgclass == 0x5) {
        }
      } elsif($msgclass == 0x7) { # else if real data
        print $outfile $strmdata if defined $outfile;
        if(defined $playpipe) {
          $select->can_write();
          print $playpipe $strmdata;
        }
      }
    }
  }
  $socket->close();
}

sub config {
  $ignore{'Alicia Keys'} = 1;
  $ignore{'Angie Stone'} = 1;
  $ignore{'REO Speedwagon'} = 1;
  $ignore{'Poison'} = 1;
  $ignore{'Nelly'} = 1;
  $ignore{'Christina Aguilera'} = 1;
  $ignore{'Milli Vanilli'} = 1;
  $ignore{'Michael Jackson'} = 1;
  $ignore{'Whitney Houston'} = 1;
  $ignore{'The Flaming Lips'} = 1;
  $ignore{'Aaliyah'} = 1;
  $ignore{'Taylor Dayne'} = 1;
  $ignore{'Beastie Boys'} = 1;
  $ignore{'Steve Perry'} = 1;
  $ignore{'Steve Earle'} = 1;
  $ignore{'Eminem'} = 1;
  $ignore{'Janet Jackson'} = 1;
  $ignore{'Journey'} = 1;
  $ignore{'Loverboy'} = 1;
  $ignore{'Patrick Swayze'} = 1;
  $ignore{'Prince'} = 1;
  $ignore{'Ratt'} = 1;
  $ignore{'Tommy Lee'} = 1;
  $ignore{'Warrant'} = 1;
  $ignore{'White Zombie'} = 1;
  $ignore{'Twisted Sister'} = 1;
  $ignore{'Sheena Easton'} = 1;
  $ignore{'Quiet Riot'} = 1;
  $ignore{'Loverboy'} = 1;
  $ignore{'Motley Crue'} = 1;
  $ignore{'Great White'} = 1;
  $ignore{'Flaming Lips'} = 1;
  $ignore{'Clint Black'} = 1;
  $ignore{'Busta Rhymes'} = 1;
  $ignore{'Dolly Parton'} = 1;
  $ignore{'Bobby Brown'} = 1;
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

sub shutdown {
  undef $playpipe if defined $playpipe;
  if(defined $outfile) {
    undef $outfile;
    unlink $filename; # remove partial file
  }
  exit;
}

sub txtdecode {
  my $txt = shift;
  $txt =~ s/&apos;/'/g;
  $txt =~ s/&quot;/"/g;
  $txt =~ s/&amp;/&/g;
  $txt =~ s/&gt;/>/g;
  $txt =~ s/&lt;/</g;
  return $txt;
}
