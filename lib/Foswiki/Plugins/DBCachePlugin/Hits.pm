# Plugin for Foswiki - The Free and Open Source Wiki, http://foswiki.org/
#
# Copyright (C) 2005-2017 Michael Daum http://michaeldaumconsulting.com
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
###############################################################################

package Foswiki::Plugins::DBCachePlugin::Hits;

use strict;
use warnings;

use Foswiki::Func ();
use Foswiki::Plugins::DBCachePlugin ();

use Foswiki::Iterator ();
our @ISA = ('Foswiki::Iterator');

sub new {
  my $class = shift;

  my $this = bless({
      sorting => "off",
      reverse => 0,
      @_
    },
    $class
  );

  $this->{reverse} = Foswiki::Func::isTrue($this->{reverse});

  # init internal vars
  $this->{_objects} = {};
  $this->{_isNumerical} = 1;
  $this->{_index} = 0;
  $this->{_count} = 0;
  $this->{_sortPropOfTopic} = {};
  $this->{_sortIndex} = undef;

  return $this;
}

sub add {
  my ($this, $topic, $obj) = @_;

  my $web = $obj->fastget("web");
  my $key = $web . "." . $topic;
  $this->{_objects}{$key} = $obj;

  # sort by name
  if ($this->{sorting} =~ /^(on|name)$/) {
    $this->{_sortPropOfTopic}{$key} = $topic;
    $this->{_isNumerical} = 0;
  }

  # sort by create date
  elsif ($this->{sorting} =~ /^created/) {
    $this->{_sortPropOfTopic}{$key} = $obj->fastget('createdate');
  }

  # sort by date
  elsif ($this->{sorting} =~ /^(modified|info\.date)/) {
    my $info = $obj->fastget('info');
    $this->{_sortPropOfTopic}{$key} = $info ? $info->fastget('date') : 0;
  }

  # sort randomly
  elsif ($this->{sorting} =~ /^rand(om)?$/) {
    $this->{_sortPropOfTopic}{$key} = rand();
  }

  # sort by time added
  elsif ($this->{sorting} =~ /^off$/i) {
    $this->{_sortPropOfTopic}{$key} = $this->{_count};
  }

  # sort by property
  else {
    my $format = $this->{sorting};
    $format =~ s/\$web/$web/g;
    $format =~ s/\$topic/$topic/g;
    $format =~ s/\$perce?nt/\%/go;
    $format =~ s/\$nop//go;
    $format =~ s/\$n/\n/go;
    $format =~ s/\$dollar/\$/go;

    my @crits = ();
    foreach my $item (split(/\s*,\s*/, $format)) {
      push @crits, $item;
    }

    my $path = join(" and ", @crits);
    $this->{_sortPropOfTopic}{$key} = $this->_expandPath($obj, $path) || '';

    #print STDERR "key=$key, path=$path, sortProp=".$this->{_sortPropOfTopic}{$key}."\n";

    $this->{_isNumerical} = 0
      if $this->{_isNumerical} && $this->{_sortPropOfTopic}{$key} && !($this->{_sortPropOfTopic}{$key} =~ /^[+-]?\d+(\.\d+)?$/);
  }

  $this->{_count}++;

  return $obj;
}

sub _getDB {
  my ($this, $obj) = @_;

  return Foswiki::Plugins::DBCachePlugin::getDB($obj->fastget("web"));
}

sub _expandPath {
  my ($this, $obj, $path) = @_;

  my $db = $this->_getDB($obj);
  return "" unless $db;
  return $db->expandPath($obj, $path);
}

sub init {
  my $this = shift;

  return if defined $this->{_sortIndex};

  my @keys = keys %{$this->{_objects}};

  my $props = $this->{_sortPropOfTopic};

  if (scalar(@keys) > 1) {
    if ($this->{_isNumerical}) {
      @keys =
        sort { ($props->{$a} || 0) <=> ($props->{$b} || 0) || $a cmp $b } @keys;
    } else {
      @keys =
        sort { $props->{$a} cmp $props->{$b} || $a cmp $b } @keys;
    }
    @keys = reverse @keys if $this->{reverse};
  }

  $this->{_sortIndex} = \@keys;

  return;
}

sub count {
  my $this = shift;

  return $this->{_count};
}

# iterator api
sub hasNext {
  my $this = shift;

  return $this->{_index} < $this->{_count} ? 1 : 0;
}

sub skip {
  my ($this, $num) = @_;

  $this->{_index} += $num;

  if ($this->{_index} < 0) {
    $this->{_index} = 0;
  } elsif ($this->{_index} > $this->{_count}) {
    $this->{_index} = $this->{_count};
  }

  return $this->{_index};
}

sub next {
  my $this = shift;

  $this->init;

  return unless $this->hasNext;

  my $key = $this->{_sortIndex}[$this->{_index}++];

  return unless $key;
  return $this->{_objects}{$key};
}

sub reset {
  my $this = shift;

  $this->{_index} = 0;
  $this->{_sortIndex} = undef;

  return 1;
}

sub all {
  my $this = shift;

  $this->init;
  return @{$this->{_sortIndex}};
}

1;
