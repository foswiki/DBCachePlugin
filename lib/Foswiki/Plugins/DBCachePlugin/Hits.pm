# Plugin for Foswiki - The Free and Open Source Wiki, http://foswiki.org/
#
# Copyright (C) 2005-2026 Michael Daum http://michaeldaumconsulting.com
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details, published at
# http://www.gnu.org/copyleft/gpl.html
#

package Foswiki::Plugins::DBCachePlugin::Hits;

use strict;
use warnings;

use Foswiki::Func ();
use Foswiki::Time ();
use Foswiki::Plugins::DBCachePlugin ();

use Foswiki::Iterator ();
our @ISA = ('Foswiki::Iterator');

sub new {
  my $class = shift;

  my $this = bless({
      sorting => "off",
      reverse => "",
      @_
    },
    $class
  );

  # init internal vars
  $this->{_position} = 0; # position within sort index while iterating
  $this->{_count} = 0; # number of items in hit set
  $this->{_objects} = {}; # hash of objects being sorted
  $this->{_isMultiKey} = {}; # hash of booleans indicating whether a property is a multi key
  $this->{_isNumerical} = {}; # hash of booleans indicating whether a property is numerical
  $this->{_isReverse} = undef; # hash of booleans indicating whether a property is sorted in reverse
  $this->{_propValue} = {}; # hashes of properties extracted from objects
  $this->{_propNames} = undef; # list of properties 
  $this->{_sortIndex} = undef; # computed sorting

  #print STDERR "sorting=$this->{sorting}, reverse=$this->{reverse}\n";

  return $this;
}

sub DESTROY {
  my $this = shift;

  undef $this->{_objects};
  undef $this->{_isMultiKey};
  undef $this->{_isNumerical};
  undef $this->{_isReverse};
  undef $this->{_propValue};
  undef $this->{_propNames};
  undef $this->{_sortIndex};
}

sub add {
  my ($this, $web, $name, $obj) = @_;

  my $key = $name;
  $key = $web . "." . $key if defined $web;

  $this->{_objects}{$key} = $obj;
  $this->{_propNames} = [];

  # sort by name
  if ($this->{sorting} =~ /^(on|name)$/) {
    my $propName = $1;
    $this->{_propValue}{$key} = {
      $propName => $name
    };
    $this->{_isNumerical}{$propName} = 0;
    $this->{_isMultiKey}{$propName} = 0;
    push @{$this->{_propNames}}, $propName;
  }

  # sort by create date
  elsif ($this->{sorting} =~ /^(created(ate)?)$/) {
    my $propName = $1;
    $this->{_propValue}{$key} = {
      $propName => $obj->fastget('createdate')
    };
    $this->{_isNumerical}{$propName} = 1;
    $this->{_isMultiKey}{$propName} = 0;
    push @{$this->{_propNames}}, $propName;
  }

  # sort by date
  elsif ($this->{sorting} =~ /^((modified|info\.date))$/) {
    my $propName = $1;
    my $date = $obj->fastget($propName); # first try directly
    unless (defined $date) {
      my $info = $obj->fastget('info'); # then use the topicinfo
      $date = $info ? $info->fastget('date') : 0
    }
    $this->{_propValue}{$key} = {
      $propName => $date || 0
    };
    $this->{_isNumerical}{$propName} = 1;
    $this->{_isMultiKey}{$propName} = 0;
    push @{$this->{_propNames}}, $propName;
  }

  # sort randomly
  elsif ($this->{sorting} =~ /^rand(om)?$/) {
    my $propName = $1;
    $this->{_propValue}{$key} = {
      $propName => rand()
    };
    push @{$this->{_propNames}}, $propName;
    $this->{_isNumerical}{$propName} = 1;
    $this->{_isMultiKey}{$propName} = 0;
    push @{$this->{_propNames}}, $propName;
  }

  # sort by time added
  elsif ($this->{sorting} =~ /^(off)$/i) {
    my $propName = $1;
    $this->{_propValue}{$key} = {
      $propName => $this->{_count}
    };
    $this->{_isNumerical}{$propName} = 1;
    $this->{_isMultiKey}{$propName} = 0;
    push @{$this->{_propNames}}, $propName;
  }

  # sort by property
  else {
    my $format = $this->{sorting};
    $format =~ s/\$web/$web/g;
    $format =~ s/\$topic/$name/g;
    $format =~ s/\$name/$name/g;
    $format =~ s/\$perce?nt/\%/g;
    $format =~ s/\$nop//g;
    $format =~ s/\$n/\n/g;
    $format =~ s/\$dollar/\$/g;
    $format =~ s/^\s+//;
    $format =~ s/\s+$//;

    foreach my $prop (split(/\s*,\s*/, $format)) {
      my $val = $this->_expandPath($web, $obj, $prop) // '';
      push @{$this->{_propNames}}, $prop;

      $this->{_isNumerical}{$prop} //= 0;
      $this->{_isMultiKey}{$prop} //= 0;

      if ($val ne "") {
        if ( $val =~ /^[+-]?\d+(\.\d+)?$/) {
          $this->{_isNumerical}{$prop} = 1;
        } elsif ($val =~ /^(\w(.\w+)+)|\d+$/) {
          $this->{_isMultiKey}{$prop} = 1;
          $this->{_isNumerical}{$prop} = 0;
        } else {
          my $epoch = Foswiki::Time::parseTime($val);

          if (defined $epoch) {
            $val = $epoch;
            $this->{_isNumerical}{$prop} = 1;
          }
        }
      }

      my $rec = $this->{_propValue}{$key} || {};
      $rec->{$prop} = $val;
      $this->{_propValue}{$key} = $rec;

      #print STDERR "prop=$prop, val=$val, isNumerical=$this->{_isNumerical}{$prop}, key=$key\n";
    }
  }

  unless (defined $this->{_isReverse}) {
    foreach my $prop (@{$this->{_propNames}}) {
      $this->{_isReverse}{$prop} = (defined($this->{reverse}) && $prop ne 'off' && ($this->{reverse} =~ /\Q$prop\E/ || $this->{reverse} =~ /^(?:on|1|yes|true)$/)) ? 1:0;
      #print STDERR "isReverse($prop)=$this->{_isReverse}{$prop}\n";
    }
  }

  $this->{_count}++;

  return $obj;
}

sub _expandPath {
  my ($this, $web, $obj, $path) = @_;

  return "" unless defined $web;

  my $db = Foswiki::Plugins::DBCachePlugin::getDB($web);
  return "" unless $db;

  return $db->expandPath($obj, $path);
}

#use Data::Dump qw(dump);
sub init {
  my $this = shift;

  return if defined $this->{_sortIndex};

  my @keys = keys %{$this->{_objects}};

  #print STDERR "propVals=".dump($this->{_propValue})."\n";

  @keys = sort {$this->compare($a, $b)} @keys if scalar(@keys) > 1;

  $this->{_sortIndex} = \@keys;

  return;
}

sub compare {
  my ($this, $a, $b, $index) = @_;

  $index ||= 0;
  my $prop = $this->{_propNames}[$index];
  return 0 unless defined $prop;

  my $valA = $this->{_propValue}{$a}{"$prop"};
  my $valB = $this->{_propValue}{$b}{"$prop"};

  #print STDERR "prop=$prop, isNumerical=$this->{_isNumerical}{$prop}, isMultiKey=$this->{_isMultiKey}{$prop}, isReverse=$this->{_isReverse}{$prop}\n";
  my $result;
  if ($this->{_isMultiKey}{$prop}) {
    $result = ($this->{_isReverse}{$prop}) ? multiKeyCmp($valB, $valA) : multiKeyCmp($valA, $valB);
  } elsif ($this->{_isNumerical}{$prop}) {
    # sort undefined values to the end
    if ($this->{_isReverse}{$prop}) {
      $valA = 0 if !defined($valA) || $valA eq ''; # a large int
      $valB = 0 if !defined($valB) || $valB eq '';
      $result = $valB <=> $valA;
    } else {
      $valA = 90071992547409920 if !defined($valA) || $valA eq ''; # a large int
      $valB = 90071992547409920 if !defined($valB) || $valB eq '';
      $result = $valA <=> $valB;
    }
  } else {
    $valA //= '';
    $valB //= '';
    $result  = ($this->{_isReverse}{$prop}) ? $valB cmp $valA : $valA cmp $valB;
  }

  #print STDERR "a=$a, b=$b, valA=$valA, valB=$valB, prop=$prop, result=$result\n";

  return $result == 0 ? $this->compare($a, $b, $index+1): $result;
}

# from https://metacpan.org/dist/Sort-Versions/source/lib/Sort/Versions.pm
sub multiKeyCmp {
  my @A = ($_[0] =~ /([-.]|\d+|[^-.\d]+)/g);
  my @B = ($_[1] =~ /([-.]|\d+|[^-.\d]+)/g);

  my ($A, $B);
  while (@A and @B) {
    $A = shift @A;
    $B = shift @B;
    if ($A eq '-' and $B eq '-') {
      next;
    } elsif ($A eq '-') {
      return -1;
    } elsif ($B eq '-') {
      return 1;
    } elsif ($A eq '.' and $B eq '.') {
      next;
    } elsif ($A eq '.') {
      return -1;
    } elsif ($B eq '.') {
      return 1;
    } elsif ($A =~ /^\d+$/ and $B =~ /^\d+$/) {
      return $A <=> $B if $A <=> $B;
    } else {
      $A = uc $A;
      $B = uc $B;
      return $A cmp $B if $A cmp $B;
    }
  }
  @A <=> @B;
}

sub count {
  my $this = shift;

  return $this->{_count};
}

# iterator api
sub hasNext {
  my $this = shift;

  return $this->{_position} < $this->{_count} ? 1 : 0;
}

sub skip {
  my ($this, $num) = @_;

  $this->{_position} += $num;

  if ($this->{_position} < 0) {
    $this->{_position} = 0;
  } elsif ($this->{_position} > $this->{_count}) {
    $this->{_position} = $this->{_count};
  }

  return $this->{_position};
}

sub next {
  my $this = shift;

  $this->init;

  return unless $this->hasNext;

  my $key = $this->{_sortIndex}[$this->{_position}++];

  return unless $key;
  return $this->{_objects}{$key};
}

sub reset {
  my $this = shift;

  $this->{_position} = 0;

  return 1;
}

sub all {
  my $this = shift;

  $this->init;
  return @{$this->{_sortIndex}};
}

1;
