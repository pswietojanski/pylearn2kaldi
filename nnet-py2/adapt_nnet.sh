#!/bin/bash

# Copyright 2014 Pawel Swietojanski
# Apache 2.0

# Begin configuration section.  
iter=
nnet= # You can specify the nnet to use (e.g. if you want to use the .alinnet)
feature_transform= # You can specify the feature transform to use for the feedforward
model= # You can specify the transition model to use (e.g. if you want to use the .alimdl)
class_frame_counts= # You can specify frame count to compute PDF priors 
nj=4
cmd=run.pl
best_path_cmd=
max_active=7000
beam=13.0 # GMM:13.0
latbeam=9.0 # GMM:6.0
acwt=0.1 # GMM:0.0833, note: only really affects pruning (scoring is on lattices).
min_lmwt=9
max_lmwt=15
score_args=
scale_opts="--transition-scale=1.0 --acoustic-scale=0.1 --self-loop-scale=0.1"
transform_dir= #
ctx_win=4
norm_vars=false
asclite=true
model_yaml=
model_conf=
model_pytables=
adapt_yaml=
align_dir=
stage=0
retry_beam=40
freeze_regex="softmax_[Wb]|h[0-9]_[Wb]|nlrf_[Wb]"
do_splicing=false
oracle=false
# End configuration section.

echo "$0 $@"  # Print the command line for logging

[ -f ./path.sh ] && . ./path.sh; # source the path.
. parse_options.sh || exit 1;

if [ $# != 5 ]; then
   echo "Usage: $0 [options] <data-dir> <lang-dir> <gmm-dir> <work-dir> <si-dir>"
   echo "... where <decode-dir> is assumed to be a sub-directory of the directory"
   echo " where the model is."
   echo "e.g.: $0 exp/mono/graph_tgpr data/test_dev93 exp/mono/decode_dev93_tgpr"
   echo ""
   echo "This script works on CMN + (delta+delta-delta | LDA+MLLT) features; it works out"
   echo "what type of features you used (assuming it's one of these two)"
   echo ""
   echo "main options (for others, see top of script file)"
   echo "  --config <config-file>                           # config containing options"
   echo "  --nj <nj>                                        # number of parallel jobs"
   echo "  --iter <iter>                                    # Iteration of model to test."
   echo "  --nnet <nnet>                                    # which nnet to use (e.g. to"
   echo "  --model <model>                                  # which model to use (e.g. to"
   echo "                                                   # specify the final.nnet)"
   echo "  --cmd (utils/run.pl|utils/queue.pl <queue opts>) # how to run jobs."
   echo "  --transform-dir <trans-dir>                      # dir to find fMLLR transforms "
   echo "                                                   # speaker-adapted decoding"
   exit 1;
fi

data=$1
lang=$2
gmm_dir=$3
dir=$4
srcdir=`dirname $dir`; # The model directory is one level up from decoding directory.
sdata=$data/split$nj;
sidir=`dirname $adapt_yaml`
sidir_dec=$5 #this is the 1st pass dir with lattices

[[ -f $model_yaml && -f $model_conf ]] || exit 1;
if [ "$oracle" == "true" ]; then
  oov=`cat $lang/oov.int` || exit 1;
fi

for pytable in $model_pytables; do
  [ ! -f $pytable ] && echo "File $pytable not found." && exit 1;
done

if [ -z "$best_path_cmd" ]; then
  best_path_cmd=$cmd
fi

mkdir -p $dir/log
[[ -d $sdata && $data/feats.scp -ot $sdata ]] || split_data.sh $data $nj || exit 1;
echo $nj > $dir/num_jobs

cp $gmm_dir/tree $dir/
cp $gmm_dir/final.mdl $dir/

if [ -z "$model" ]; then # if --model <mdl> was not specified on the command line...
  model=$srcdir/final.mdl;
fi

for f in $sdata/1/feats.scp $model;
do
  [ ! -f $f ] && echo "$0: no such file $f" && exit 1;
done

# PREPARE THE LOG-POSTERIOR COMPUTATION PIPELINE
if [ "" == "$class_frame_counts" ]; then
  class_frame_counts=$srcdir/ali_train.counts
else
  echo "Overriding class_frame_counts by $class_frame_counts"
fi

# splice the features for the context window:
if $do_splicing; then
  splice_opts="--left-context=$ctx_win --right-context=$ctx_win"
  feats="ark:splice-feats $splice_opts scp:$sdata/JOB/feats.scp ark:- |"
  echo "Splicing using Kaldi tools."
else
  feats="ark:copy-feats scp:$sdata/JOB/feats.scp ark:- |"
fi

# Finally add feature_transform and the MLP
#--priors $class_frame_counts 
feats="$feats ptgl.sh --cpu --use-sge --cnn-conf $model_conf kaldi_fwdpass.py --debug False --decoder-yaml $model_yaml \
--model-pytables \"$model_pytables\" --priors $class_frame_counts |"

if [[ $stage -le 0 && -z "$align_dir" ]]; then

  #generate alignments using si-model
  if [ "$oracle" == "true" ]; then
    echo "$0: aligning data from $sdata/JOB/text and putting alignemts in '$dir'"
    # Map oovs in reference transcription "
    tra="ark:utils/sym2int.pl --map-oov $oov -f 2- $lang/words.txt $sdata/JOB/text|";
    # We could just use align-mapped in the next line, but it's less efficient as it compiles the
    # training graphs one by one.
    $cmd JOB=1:$nj $dir/log/align.JOB.log \
     compile-train-graphs $srcdir/tree $srcdir/final.mdl  $lang/L.fst "$tra" ark:- \| \
     align-compiled-mapped $scale_opts --beam=$beam --retry-beam=$retry_beam $dir/final.mdl ark:- \
       "$feats" "ark:|gzip -c >$dir/ali.JOB.gz" || exit 1
  else
    echo "$0: getting best path alignments from $sidir_dec putting alignemts in '$dir'"
    LMWT=12
    $cmd JOB=1:$nj $dir/log/best_path.JOB.log lattice-best-path --lm-scale=$LMWT --word-symbol-table=$lang/words.txt \
      "ark:gunzip -c $sidir_dec/lat.*.gz|" ark,t:$dir/JOB.tra "ark:|gzip -c > $dir/ali.JOB.gz" || exit 1;
  fi

  $cmd JOB=1:1 $dir/ali2pdf.log ali-to-pdf $dir/final.mdl ark:"gunzip -c $dir/ali.*.gz |" \
     ark,t:"$dir/ali.pdf" || exit 1
  
  alipdf=$dir/ali.pdf

#elif [ ! -z "$align_dir" ]; then
#  echo 'Not implemented'; exit 1;
else
  if [ -z "$align_dir" ]; then
    align_dir=$dir
  fi
  echo "Using $align_dir/ali.pdf as the targets"
  alipdf=$align_dir/ali.pdf
fi

echo "$0: adapting si-model $dir to speaker"

#speaker adaptation, the lists are already split per speakers
$cmd JOB=1:$nj $dir/log/adapt.JOB.log \
   ptgl.sh --cpu --use-sge --cnn-conf $model_conf adaptation.py --job JOB --adapt-yaml $adapt_yaml \
      --model-pytables $model_pytables --freeze-regex "\"$freeze_regex\"" \
      $sidir $dir $sdata/JOB/feats.scp $alipdf

exit 0;
