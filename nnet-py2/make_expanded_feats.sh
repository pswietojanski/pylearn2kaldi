#!/bin/bash

# Copyright 2014, University of Edinburgh (Author: Pawel Swietojanski)
#                 
# Apache 2.0.
#
# Begin configuration section.  
nj=4
cmd=run.pl
transform_dir=
force_cmvn=false
glob_cmvn=false
# End configuration section.

echo "$0 $@"  # Print the command line for logging

[ -f ./path.sh ] && . ./path.sh; # source the path.
. parse_options.sh || exit 1;

if [ $# != 3 ]; then
   echo "Usage: $0 [options] <tgt-data-dir> <src-data-dir> <gmm-dir> "
   echo "e.g.: $0 data-fmllr/train data/train exp/tri5a exp/make_fmllr_feats/log plp/processed/"
   echo ""
   echo "This script works on CMN + (delta+delta-delta | LDA+MLLT) features; it works out"
   echo "what type of features you used (assuming it's one of these two)"
   echo "You can also use fMLLR features-- you have to supply --transform-dir option."
   echo ""
   echo "main options (for others, see top of script file)"
   echo "  --config <config-file>                           # config containing options"
   echo "  --nj <nj>                                        # number of parallel jobs"
   echo "  --cmd (utils/run.pl|utils/queue.pl <queue opts>) # how to run jobs."
   echo "  --transform-dir <transform-dir>                  # where to find fMLLR transforms."
   echo "  --force-cmvn [true/false]                        # ignore cmvn_opts (only when transoform is null)."
   echo "  --glob-cmvn [true/false]                         # apply global cmvn normalisation at the end."
   exit 1;
fi

data=$1
srcdata=$2
gmmdir=$3

logdir=$data/log
feadir=$data/data

sdata=$srcdata/split$nj;
splice_opts=`cat $gmmdir/splice_opts 2>/dev/null` # frame-splicing options.

if [ "$force_cmvn" == "true" ]; then
  
  #one should use this option with fbank, or delta features only. Otherwise possibly different cmvn options may break lda/fmllr transforms
  [ ! -z $transform_dir ] && echo "$0. CMVN forced with --transform-dir. This might introduce a mismatch. Exiting." && exit 1;
  [ -f $gmmdir/final.mat ] && echo "$0. CMVN forced but looks like feats are lda-type. This might introduce a mismatch. Exiting." && exit 1;

  cmvn_opts="--norm-means=true --norm-vars=false"
else
  cmvn_opts=`cat $gmmdir/cmvn_opts 2>/dev/null`
fi

mkdir -p $data $logdir $feadir
[[ -d $sdata && $srcdata/feats.scp -ot $sdata ]] || split_data.sh $srcdata $nj || exit 1;

for f in $sdata/1/feats.scp $sdata/1/cmvn.scp; do
  [ ! -f $f ] && echo "$0: no such file $f" && exit 1;
done

if [ -f $gmmdir/final.mat ]; then feat_type=lda; else feat_type=delta; fi
echo "$0: feature type is $feat_type with cmvn opts $cmvn_opts"

case $feat_type in
  delta) feats="ark,s,cs:apply-cmvn $cmvn_opts --utt2spk=ark:$sdata/JOB/utt2spk scp:$sdata/JOB/cmvn.scp scp:$sdata/JOB/feats.scp ark:- | add-deltas ark:- ark:- |";;
  lda) feats="ark,s,cs:apply-cmvn $cmvn_opts --utt2spk=ark:$sdata/JOB/utt2spk scp:$sdata/JOB/cmvn.scp scp:$sdata/JOB/feats.scp ark:- | splice-feats $splice_opts ark:- ark:- | transform-feats $gmmdir/final.mat ark:- ark:- |";;
  *) echo "Invalid feature type $feat_type" && exit 1;
esac

if [ ! -z "$transform_dir" ]; then # add transforms to features...
  echo "Using fMLLR transforms from $transform_dir"
  [ ! -f $transform_dir/trans.1 ] && echo "Expected $transform_dir/trans.1 to exist." && exit 1
  feats="$feats transform-feats --utt2spk=ark:$sdata/JOB/utt2spk \"ark:cat $transform_dir/trans.* |\" ark:- ark:- |"
fi

if [ $glob_cmvn ]; then
  echo "Computing global CMVN stats"
  cmvnfeats=`echo $feats | sed -r "s?$sdata/JOB?$srcdata?g"`
  compute-cmvn-stats "$cmvnfeats" $data/cmvn_glob || exit 1;
  feats="$feats apply-cmvn --norm-means=true --norm-vars=true $data/cmvn_glob ark:- ark:- |"
fi

# prepare the dir
cp $srcdata/* $data 2>/dev/null; rm $data/{feats,cmvn}.scp;

# make $bnfeadir an absolute pathname.
feadir=`perl -e '($dir,$pwd)= @ARGV; if($dir!~m:^/:) { $dir = "$pwd/$dir"; } print $dir; ' $feadir ${PWD}`

name=`basename $data`

# forward the feats
$cmd JOB=1:$nj $logdir/make_expanded_feats.JOB.log \
  copy-feats "$feats" \
  ark,scp:$feadir/feats_${feat_type}_$name.JOB.ark,$feadir/feats_${feat_type}_$name.JOB.scp || exit 1;
   
# merge the SCPs
for n in $(seq 1 $nj); do
  cat $feadir/feats_${feat_type}_$name.$n.scp 
done > $data/feats.scp

echo "$0 finished... $srcdata -> $data ($gmmdir)"

exit 0;
