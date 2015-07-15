#!/bin/bash

# Begin configuration section.  
nj=4
cmd=run.pl
stage=0
# Begin configuration.
scale_opts="--transition-scale=1.0 --acoustic-scale=0.1 --self-loop-scale=0.1"
beam=10
retry_beam=40
ctx_win=
do_splicing=false

align_to_lats=false # optionally produce alignment in lattice format
lats_decode_opts="--acoustic-scale=0.1 --beam=20 --lattice_beam=10"
lats_graph_scales="--transition-scale=1.0 --self-loop-scale=0.1"

#pylearn2 specific options
decoder_yaml=
model_conf=
model_pytables_si=

# End configuration options.

[ $# -gt 0 ] && echo "$0 $@"  # Print the command line for logging

[ -f path.sh ] && . ./path.sh # source the path.
. parse_options.sh || exit 1;

if [ $# != 4 ]; then
   echo "usage: $0 <data-dir> <lang-dir> <src-dir> <align-dir>"
   echo "e.g.:  $0 data/train data/lang exp/tri1 exp/tri1_ali"
   echo "main options (for others, see top of script file)"
   echo "  --config <config-file>                           # config containing options"
   echo "  --nj <nj>                                        # number of parallel jobs"
   echo "  --cmd (utils/run.pl|utils/queue.pl <queue opts>) # how to run jobs."
   echo "  --decoder-yaml  "
   echo "  --model-conf  "
   echo "  --model-pytables-si  "
   exit 1;
fi

data=$1
lang=$2
srcdir=$3
dir=$4

flist="$decoder_yaml $model_pytables_si $model_conf"
for f in $flist; do
  [ -z "$f" ] && continue;
  [ ! -f "$f" ] && echo "File $f is missing." && exit 1;
done

oov=`cat $lang/oov.int` || exit 1;
mkdir -p $dir/log
echo $nj > $dir/num_jobs
sdata=$data/split$nj
[[ -d $sdata && $data/feats.scp -ot $sdata ]] || split_data.sh $data $nj || exit 1;

cp $srcdir/{tree,final.mdl} $dir || exit 1;

# Select default locations to model files
# PREPARE THE LOG-POSTERIOR COMPUTATION PIPELINE
if [ "" == "$class_frame_counts" ]; then
  class_frame_counts=$srcdir/ali_train.counts
  echo "Using standard priors $class_frame_counts"
else
  echo "Overriding class_frame_counts by $class_frame_counts"
fi
model=$dir/final.mdl

# Check that files exist
for f in $sdata/1/feats.scp $sdata/1/text $lang/L.fst $model $class_frame_counts; do
  [ ! -f $f ] && echo "$0: missing file $f" && exit 1;
done

# PREPARE FEATURE EXTRACTION PIPELINE
# splice the features for the context window:
if $do_splicing; then
  splice_opts="--left-context=$ctx_win --right-context=$ctx_win"
  feats="ark:splice-feats $splice_opts scp:$sdata/JOB/feats.scp ark:- |"
else
  feats="ark:copy-feats scp:$sdata/JOB/feats.scp ark:- |"
fi

# Finally add feature_transform and the MLP
feats="$feats ptgl.sh --use-sge --cnn-conf $model_conf kaldi_fwdpass.py --debug False --decoder-yaml $decoder_yaml \
--model-pytables $model_pytables_si --priors $class_frame_counts |"

echo "$0: aligning data '$data' using nnet/model '$srcdir', putting alignments in '$dir'"
# Map oovs in reference transcription 
tra="ark:utils/sym2int.pl --map-oov $oov -f 2- $lang/words.txt $sdata/JOB/text|";
# We could just use align-mapped in the next line, but it's less efficient as it compiles the
# training graphs one by one.
if [ $stage -le 0 ]; then
  $cmd JOB=1:$nj $dir/log/align.JOB.log \
    compile-train-graphs $dir/tree $dir/final.mdl  $lang/L.fst "$tra" ark:- \| \
    align-compiled-mapped $scale_opts --beam=$beam --retry-beam=$retry_beam $dir/final.mdl ark:- \
      "$feats" "ark,t:|gzip -c >$dir/ali.JOB.gz" || exit 1;
fi

# Optionally align to lattice format (handy to get word alignment)
if [ "$align_to_lats" == "true" ]; then
  echo "$0: aligning also to lattices '$dir/lat.*.gz'"
  $cmd JOB=1:$nj $dir/log/align_lat.JOB.log \
    compile-train-graphs $lat_graph_scale $dir/tree $dir/final.mdl  $lang/L.fst "$tra" ark:- \| \
    latgen-faster-mapped $lat_decode_opts --word-symbol-table=$lang/words.txt $dir/final.mdl ark:- \
      "$feats" "ark:|gzip -c >$dir/lat.JOB.gz" || exit 1;
fi

echo "$0: done aligning data."
