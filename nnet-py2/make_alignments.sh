#!/bin/bash

#Copyright 2013, Pawel Swietojanski

if [ $# -lt 3 ]; then
  echo 'Usage: <ali-dir> <out-dir> <ali-suffix>'
  exit 1;
fi

alidir=$1
dir=$2
suffix=$3

if [ ! -f $alidir/final.mdl -o ! -f $alidir/ali.1.gz ]; then
  echo "Error: alignment dir $alidir does not contain final.mdl or ali"
  exit 1;
fi

mkdir -p $dir/log

echo "Preparing phone alignments"
phone_labels="$dir/ali_${suffix}.phones"
ali-to-phones --per-frame=True $alidir/final.mdl ark:"gunzip -c $alidir/ali.*.gz |" \
  ark,t:"$dir/ali_${suffix}.phones" 2> $dir/log/ali2phones_${suffix}.log || exit 1
hmm-info --print-args=False $alidir/final.mdl | grep phones | cut -d" " -f4 > $dir/num_phones || exit 1

echo "Preparing state alignments"
state_labels="ark:$dir/ali_${suffix}.pdf"
ali-to-pdf $alidir/final.mdl ark:"gunzip -c $alidir/ali.*.gz |" \
  ark,t:"$dir/ali_${suffix}.pdf" 2> $dir/ali2pdf_${suffix}.log || exit 1
hmm-info --print-args=False $alidir/final.mdl | grep pdf | cut -d" " -f4 > $dir/num_states || exit 1
#generate calss counts for training set only
pdf-to-counts "$state_labels" $dir/ali_${suffix}.counts

exit 0;
