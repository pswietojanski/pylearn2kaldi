#!/bin/bash

# Copyright 2013 Pawel Swietojanski
# Apache 2.0

# Begin configuration section.  
iter=
nnet= # You can specify the nnet to use (e.g. if you want to use the .alinnet)
feature_transform= # You can specify the feature transform to use for the feedforward
model= # You can specify the transition model to use (e.g. if you want to use the .alimdl)
class_frame_counts= # You can specify frame count to compute PDF priors 
nj=4
cmd=run.pl
max_active=7000
beam=17.0 # GMM:13.0
latbeam=9.0 # GMM:6.0
acwt=0.10 # GMM:0.0833, note: only really affects pruning (scoring is on lattices).
min_lmwt=9
max_lmwt=15
score_args=
transform_dir= #
ctx_win=4
norm_vars=false
asclite=true
model_conf=
decoder_yaml=
model_pytables=
model_pytables_sd=
model_pkl=
scoring_cmd=
do_splicing=false

# End configuration section.

echo "$0 $@"  # Print the command line for logging

[ -f ./path.sh ] && . ./path.sh; # source the path.
. parse_options.sh || exit 1;

if [ $# != 3 ]; then
   echo "Usage: $0 [options] <graph-dir> <data-dir> <decode-dir>"
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

graphdir=$1
data=$2
dir=$3
srcdir=`dirname $dir`; # The model directory is one level up from decoding directory.
sdata=$data/split$nj;

#[[ -f $model_pkl && -f $model_conf ]] || exit 1;

if [ -z "$scoring_cmd" ]; then
  scoring_cmd=$cmd
fi

mkdir -p $dir/log
[[ -d $sdata && $data/feats.scp -ot $sdata ]] || split_data.sh $data $nj || exit 1;
echo $nj > $dir/num_jobs

if [ -z "$model" ]; then # if --model <mdl> was not specified on the command line...
  model=$srcdir/final.mdl;
fi

for f in $sdata/1/feats.scp $nnet $model $graphdir/HCLG.fst;
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

# get the forward prop pipeline
feats="$feats ptgl.sh --cpu --use-sge --cnn-conf $model_conf kaldi_fwdpass.py \
       --debug False --decoder-yaml $decoder_yaml \
       --model-pytables \"$model_pytables ${model_pytables_sd}JOB.h5\" \
       --priors $class_frame_counts |"

echo "$0: decoding with adapted model"
# Run the decoding in the queue
$cmd JOB=1:$nj $dir/log/decode.JOB.log \
  latgen-faster-mapped --max-active=$max_active --beam=$beam --lattice-beam=$latbeam \
  --acoustic-scale=$acwt --allow-partial=true --word-symbol-table=$graphdir/words.txt \
  $model $graphdir/HCLG.fst "$feats" "ark:|gzip -c > $dir/lat.JOB.gz" || exit 1;


# Run the scoring
[ ! -x local/score.sh ] && \
  echo "Not scoring because local/score.sh does not exist or not executable." && exit 1;
local/score.sh --min-lmwt $min_lmwt --max-lmwt $max_lmwt --cmd "$scoring_cmd" $data $graphdir $dir 2>$dir/scoring.log || exit 1;

exit 0;
