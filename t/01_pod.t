#!/usr/bin/perl
# $Id: 01_pod.t 328 2008-03-24 08:14:47Z rjray $

use Test::More;

eval "use Test::Pod 1.00";

plan skip_all => "Test::Pod 1.00 required for testing POD" if $@;

all_pod_files_ok();

exit;
