# Plugin for Foswiki - The Free and Open Source Wiki, http://foswiki.org/
#
# Copyright (C) 2026 Michael Daum http://michaeldaumconsulting.com
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

package Foswiki::Plugins::DBCachePlugin::Index;

# reverse index implementation

use strict;
use warnings;

use constant TRACE => 0;

sub new {
  my $class = shift;
  my $db = shift;

  my $this = bless({
    db => $db,
    data => {},
    isLoaded => 0,
    @_
  }, $class);

  $this->{name} //= $this->{query};

  return $this;
}

sub name {
  my $this = shift;

  return $this->{name};
}

sub add {
  my ($this, $key, $val) = @_;

  print STDERR "adding '$key'='$val' to index $this->{name}\n" if TRACE;

  $this->{data}{$key}{$val} = 1;
}

sub get {
  my ($this, $key) = @_;

  return unless exists $this->{data}{$key};
  return keys %{$this->{data}{$key}};
}

sub find {
  my ($this, $query) = @_;

  my %hits = ();

  #print STDERR "called find($query) in \n";
  #print STDERR $this->dump()."\n";

  foreach my $key (%{$this->{data}}) {
    next unless $key =~ /$query/;
    #print STDERR "... matching $key\n";
    $hits{$_} = 1 foreach keys %{$this->{data}{$key}};
  }

  return keys %hits;
}

sub remove {
  my ($this, $key, $val) = @_;

  if (defined $val) {
    delete $this->{data}{$key}{$val};
  } else {
    delete $this->{data}{$key};
  }
}

sub addObject {
  my ($this, $obj) = @_;

  if (defined $this->{process}) {
    &{$this->{process}}($this, $obj);
  } else {

    my $val = $this->{db}->expandPath($obj, $this->{query});
    $val = '_undef_' unless defined($val) && $val ne "";

    my $topic = $obj->fastget("topic");
    #print STDERR "addObject($topic) to ".$this->name()."\n" if TRACE;

    foreach my $key (split(/\s*,\s*/, $val)) {
      next unless defined $key && $key ne "";
      $this->add($key, $topic);
    }
  }
}

sub removeObject {
  my ($this, $obj) = @_;

  my $val = $obj->get($this->{propName});
  return unless defined $val;

  my $topic = $obj->fastget("topic");
  print STDERR "removeObject($topic) from ".$this->name()."\n" if TRACE;

  foreach my $key (split(/\s*,\s*/, $val)) {
    $this->remove($key, $topic);
  }
}

sub dump {
  my $this = shift;

  my @lines = ();

  foreach my $key (sort keys %{$this->{data}}) {
    my @vals = $this->get($key);
    push @lines, " - $key = (".scalar(@vals).") ".join(", ", sort @vals);
  }

  return join("\n", @lines);
}

sub load {
  my ($this, $refresh) = @_;

  return if !$refresh && $this->{isLoaded};

  my $db = $this->{db};

  foreach my $topic ($db->getKeys()) {
    my $obj = $db->fastget($topic);
    $this->addObject($obj);
  }

  $this->{isLoaded} = 1;
  #print STDERR $this->getIndex("Category")->dump."\n";
}

1;
