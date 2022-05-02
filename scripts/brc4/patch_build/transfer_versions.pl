#!/usr/env perl
=head1 LICENSE

See the NOTICE file distributed with this work for additional information
regarding copyright ownership.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=cut


use v5.14.00;
use strict;
use warnings;
use Carp;
use autodie qw(:all);
use Readonly;
use Getopt::Long qw(:config no_ignore_case);
use Log::Log4perl qw( :easy ); 
Log::Log4perl->easy_init($WARN); 
my $logger = get_logger(); 

use Bio::EnsEMBL::Registry;
use Try::Tiny;

use Data::Dumper;

###############################################################################
# MAIN
main();

sub main {
  # Get command line args
  my %opt = %{ opt_check() };

  # Get all genes from the event history file
  my $history = get_history($opt{events});
  $logger->info(sprintf("There are %d events", scalar(@$history)));
  my @replaced = grep { $_->{new_id} eq $_->{old_id} } @$history;
  $logger->info(sprintf("There are %d changed genes", scalar(@replaced)));
  #  die(Dumper(\@replaced));
  
  
  # Get metadata for each of those genes that were conserved
  my $metadata = get_genes_metadata($opt{old_registry}, $opt{species}, \@replaced);

  # Apply the gene metadata to each genes conserved
  transfer_genes_metadata($opt{new_registry}, $opt{species}, \@replaced, $opt{update});
  
  # Add the history to the stable_id history table
  # TODO
}

###############################################################################
sub get_history {
  my ($event_file) = @_;
  
  my @history;
  
  open my $hist_fh, "<", $event_file;
  while (my $line = readline $hist_fh) {
    next if $line =~ /^\s*$/;
    chomp $line;
    
    my ($new_id, $event_name, $old_id) = split("\t", $line);
    
    my %event = (
      event => $event_name,
      new_id => $new_id,
      old_id => $old_id
    );
    
    push @history, \%event;
  }
  close $hist_fh;
  
  return \@history;
}

sub get_genes_metadata {
  my ($reg_path, $species, $genes) = @_;
  
  $logger->info("Load registry");
  my $registry = 'Bio::EnsEMBL::Registry';
  $registry->load_all($reg_path, 1);
  
  my $ga = $registry->get_adaptor($species, "core", "gene");
  $logger->info("Look for genes");
  
  for my $gene (@$genes) {
    my $old_gene = $ga->fetch_by_stable_id($gene->{old_id});
    $gene->{version} = $old_gene->version;
    $gene->{description} = $old_gene->description;
    
    # Also get the transcripts and translations descriptions
    # TODO
  }
  
  return $genes;
}

sub transfer_genes_metadata {
  my ($reg_path, $species, $old_genes, $update) = @_;
  
  $logger->info("Load registry");
  my $registry = 'Bio::EnsEMBL::Registry';
  $registry->load_all($reg_path, 1);
  
  my $ga = $registry->get_adaptor($species, "core", "gene");
  $logger->info("Look for genes");
  
  my $updated = 0;
  my $updated_description = 0;
  for my $old_gene (@$old_genes) {
    my $gene = $ga->fetch_by_stable_id($old_gene->{new_id});

    $gene->version($old_gene->{version} + 1);
    my $old_desc = $old_gene->{description};
    my $new_desc = $gene->description;

    # Rules to replace the description
    my $replace = 0;
    if ($old_desc) {
      if (not $new_desc) {
        $replace = 1;
      } else {
        if ($new_desc =~ /\[Source:/ and not $old_desc =~ /\[Source:/) {
          $replace = 1;
        }
      }
    }
    
    if ($replace) {
      $logger->debug(sprintf("Replace description '%s' with '%s'", $gene->description // "", $old_gene->{description}));
      $gene->description($old_gene->{description});
    }
    
    if ($update) {
      $logger->debug(sprintf("Update gene %s with version %d", $gene->stable_id, $gene->version));
      $ga->update($gene);
    }
    $updated++;
  }
  
  if ($update) {
    $logger->info("$updated genes updated");
  } else {
    $logger->info("$updated genes would be updated (use --update to do the changes)");
  }
}

###############################################################################
# Parameters and usage
sub usage {
  my $error = shift;
  my $help = '';
  if ($error) {
    $help = "[ $error ]\n";
  }
  $help .= <<'EOF';
    Transfer gene metadata (versions etc) from gene conserved during a patch build.

    --old_registry <path> : Ensembl registry for the old database
    --new_registry <path> : Ensembl registry for the new database
    --species <str>   : production_name of one species
    --events <path>   : path to the event history file generated by gene_diff
    
    --update          : Do the actual changes
    
    --help            : show this help message
    --verbose         : show detailed progress
    --debug           : show even more information (for debugging purposes)
EOF
  print STDERR "$help\n";
  exit(1);
}

sub opt_check {
  my %opt = ();
  GetOptions(\%opt,
    "old_registry=s",
    "new_registry=s",
    "species=s",
    "events=s",
    "update",
    "help",
    "verbose",
    "debug",
  );

  usage("Old Registry needed") if not $opt{old_registry};
  usage("New Registry needed") if not $opt{new_registry};
  usage("Species needed") if not $opt{species};
  usage("Events file needed") if not $opt{events};
  usage()                if $opt{help};
  Log::Log4perl->easy_init($INFO) if $opt{verbose};
  Log::Log4perl->easy_init($DEBUG) if $opt{debug};
  return \%opt;
}

__END__

