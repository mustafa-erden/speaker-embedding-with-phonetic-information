#!/bin/bash

# Copyright      2017 Johns Hopkins University (Author: Daniel Povey)
#                2017 Johns Hopkins University (Author: Daniel Garcia-Romero)
#                2017 David Snyder
# Apache 2.0
#
# This script dumps training examples (egs) for multiclass xvector training.
# These egs consist of a data chunk and a zero-based speaker label.
# Each archive of egs has, in general, a different input chunk-size.
# We don't mix together different lengths in the same archive, because it
# would require us to repeatedly run the compilation process within the same
# training job.
#
# This script, which will generally be called from other neural net training
# scripts, extracts the training examples used to train the neural net (and
# also the validation examples used for diagnostics), and puts them in
# separate archives.


# Begin configuration section.
cmd=run.pl
min_frames_per_chunk=300
max_frames_per_chunk=500
frames_per_iter=10000000 # target number of frames per archive.
frames_per_iter_diagnostic=100000
num_diagnostic_archives=3

num_heldout_utts=100     # number of utterances held out for training subset
compress=true   # set this to false to disable compression (e.g. if you want to see whether
                # results are affected).

num_repeats=1 # number of times each speaker repeats per archive

frames_per_eg=8

left_context=4
right_context=4

stage=0
nj=6         # This should be set to the maximum number of jobs you are
             # comfortable to run in parallel; you can increase it if your disk
             # speed is greater and you have more machines.
srand=0

echo "$0 $@"  # Print the command line for logging

if [ -f path.sh ]; then . ./path.sh; fi
. parse_options.sh || exit 1;

if [ $# != 2 ]; then
  echo "Usage: $0 [opts] <data> <egs-dir>"
  echo " e.g.: $0 data/train exp/xvector_a/egs"
  echo ""
  echo "Main options (for others, see top of script file)"
  echo "  --config <config-file>                           # config file containing options"
  echo "  --nj <nj>                                        # The maximum number of jobs you want to run in"
  echo "                                                   # parallel (increase this only if you have good disk and"
  echo "                                                   # network speed).  default=6"
  echo "  --cmd (utils/run.pl;utils/queue.pl <queue opts>) # how to run jobs."
  echo "  --stage <stage|0>                                # Used to run a partially-completed training process from somewhere in"
  echo " left-context, right-context, frames-per-eg, samples-per-iter, srand, num-heldout-utts"
  echo "                                                   # the middle."

  exit 1;
fi

data=$1
dir=$2

num_utts=$(cat $data/utt2spk | wc -l)
if ! [ $num_utts -gt $[$num_heldout_utts*4] ]; then
  echo "$0: number of utterances $num_utts in your training data is too small versus num_heldout_utts $num_heldout_utts"
  echo "... you probably have so little data that it doesn't make sense to train a neural net."
  exit 1
fi

for f in $data/utt2num_frames $data/feats.scp ; do
  [ ! -f $f ] && echo "$0: expected file $f" && exit 1;
done

feat_dim=$(feat-to-dim scp:$data/feats.scp -) || exit 1
num_pdfs=$(awk '{print $2}' $data/utt2spk | sort | uniq -c | wc -l)

mkdir -p $dir/info $dir/temp
temp=$dir/temp

echo $feat_dim > $dir/info/feat_dim
cp $data/utt2num_frames $temp/utt2num_frames


if [ $stage -le 0 ]; then
  echo "$0: Preparing train and validation lists"
  # Pick a list of heldout utterances for validation egs
  # The remaining utterances are used for training egs
  awk '{print $1}' $data/utt2spk | utils/shuffle_list.pl | head -$num_heldout_utts > $temp/valid_uttlist || exit 1;

  if [ -f $data/utt2uniq ]; then  # this matters if you use data augmentation.
    echo "File $data/utt2uniq exists, so augmenting valid_uttlist to"
    echo "include all perturbed versions of the same 'real' utterances."
    mv $temp/valid_uttlist $temp/valid_uttlist.tmp
    utils/utt2spk_to_spk2utt.pl $data/utt2uniq > $temp/uniq2utt
    cat $temp/valid_uttlist.tmp | utils/apply_map.pl $data/utt2uniq | \
      sort | uniq | utils/apply_map.pl $temp/uniq2utt | \
      awk '{for(n=1;n<=NF;n++) print $n;}' | sort  > $temp/valid_uttlist
    rm $temp/uniq2utt $temp/valid_uttlist.tmp
  fi

  utils/filter_scp.pl --exclude $temp/valid_uttlist $temp/utt2num_frames > $temp/utt2num_frames.train
  utils/filter_scp.pl $temp/valid_uttlist $temp/utt2num_frames > $temp/utt2num_frames.valid

  # Pick a subset of the training list for diagnostics
  awk '{print $1}' $temp/utt2num_frames.train | utils/shuffle_list.pl | head -$num_heldout_utts > $temp/train_subset_uttlist || exit 1;
  utils/filter_scp.pl $temp/train_subset_uttlist <$temp/utt2num_frames.train > $temp/utt2num_frames.train_subset
  # Create a mapping from utterance to speaker ID (an integer)
  awk -v id=0 '{print $1, id++}' $data/spk2utt > $temp/spk2int
  utils/sym2int.pl -f 2 $temp/spk2int $data/utt2spk > $temp/utt2int
  utils/filter_scp.pl $temp/utt2num_frames.train $temp/utt2int > $temp/utt2int.train
  utils/filter_scp.pl $temp/utt2num_frames.valid $temp/utt2int > $temp/utt2int.valid
  utils/filter_scp.pl $temp/utt2num_frames.train_subset $temp/utt2int > $temp/utt2int.train_subset
fi

egs_opts="--left-context=$left_context --right-context=$right_context --compress=$compress --num-frames=$frames_per_eg"
echo $left_context > $dir/info/left_context
echo $right_context > $dir/info/right_context

# first for the training data... work out how many archives.
num_train_frames=$(awk '{n += $2} END{print n}' <$temp/utt2num_frames.train)
num_train_subset_frames=$(awk '{n += $2} END{print n}' <$temp/utt2num_frames.train_subset)
echo $num_train_frames >$dir/info/num_frames

num_train_archives=$[($num_train_frames*$num_repeats)/$frames_per_iter + 1]
echo "$0: Producing $num_train_archives archives for training"
echo $num_train_archives > $dir/info/num_archives
echo $num_diagnostic_archives > $dir/info/num_diagnostic_archives
echo $frames_per_eg > $dir/info/frames_per_eg

egs_per_archive=$[($num_train_frames*$num_repeats)/($frames_per_eg*$num_train_archives)]
echo $egs_per_archive > $dir/info/egs_per_archive

echo "$0: creating $num_train_archives archives, each with $egs_per_archive egs, with"
echo "$0:   $frames_per_eg labels per example, and (left,right) context = ($left_context,$right_context)"

if [ $nj -gt $num_train_archives ]; then
  echo "$0: Reducing num-jobs $nj to number of training archives $num_train_archives"
  nj=$num_train_archives
fi

if [ $stage -le 1 ]; then
  echo "$0: Allocating dvector training examples"
  $cmd $dir/log/allocate_dvector_examples_train.log \
    sid/nnet3/xvector/allocate_egs_dvector.py \
      --num-repeats=$num_repeats \
      --min-frames-per-chunk=$min_frames_per_chunk \
      --max-frames-per-chunk=$max_frames_per_chunk \
      --frames-per-iter=$frames_per_iter \
      --num-archives=$num_train_archives --num-jobs=$nj \
      --utt2len-filename=$dir/temp/utt2num_frames.train \
      --utt2int-filename=$dir/temp/utt2int.train --egs-dir=$dir  || exit 1

  echo "$0: Allocating dvector training subset examples"
  $cmd $dir/log/allocate_dvector_examples_train_subset.log \
    sid/nnet3/xvector/allocate_egs_dvector.py \
      --prefix train_subset \
      --num-repeats=1 \
      --min-frames-per-chunk=$min_frames_per_chunk \
      --max-frames-per-chunk=$max_frames_per_chunk \
      --frames-per-iter=$frames_per_iter_diagnostic \
      --num-archives=$num_diagnostic_archives --num-jobs=1 \
      --utt2len-filename=$dir/temp/utt2num_frames.train_subset \
      --utt2int-filename=$dir/temp/utt2int.train_subset --egs-dir=$dir  || exit 1

  echo "$0: Allocating dvector validation examples"
  $cmd $dir/log/allocate_dvector_examples_valid.log \
    sid/nnet3/xvector/allocate_egs_dvector.py \
      --prefix valid \
      --num-repeats=1 \
      --min-frames-per-chunk=$min_frames_per_chunk \
      --max-frames-per-chunk=$max_frames_per_chunk \
      --frames-per-iter=$frames_per_iter_diagnostic \
      --num-archives=$num_diagnostic_archives --num-jobs=1 \
      --utt2len-filename=$dir/temp/utt2num_frames.valid \
      --utt2int-filename=$dir/temp/utt2int.valid --egs-dir=$dir  || exit 1
fi



# The script assumes you've prepared the features ahead of time.
feats="scp,s,cs:utils/filter_scp.pl $temp/ranges.JOB $data/feats.scp |"
train_subset_feats="scp,s,cs:utils/filter_scp.pl $temp/train_subset_ranges.1 $data/feats.scp |"
valid_feats="scp,s,cs:utils/filter_scp.pl $temp/valid_ranges.1 $data/feats.scp |"


# At this stage we'll have created the ranges files that define how many egs
# there are and where they come from.  If this is your first time running this
# script, you might decide to put an exit 1 command here, and inspect the
# contents of exp/$dir/temp/ranges.* before proceeding to the next stage.
if [ $stage -le 3 ]; then
  rm $dir/.error 2>/dev/null

  echo "$0: Generating training examples on disk"
  for g in $(seq $nj); do
    outputs=$(awk '{for(i=1;i<=NF;i++)printf("ark:%s ",$i);}' $temp/outputs.$g)
    $cmd $dir/log/train_create_examples.$g.log \
      nnet3-dvector-get-egs --num-pdfs=$num_pdfs $egs_opts \
        $temp/ranges.$g "`echo $feats | sed s/JOB/$g/g`" $outputs || touch $dir/.error &
  done
  wait

  train_subset_outputs=$(awk '{for(i=1;i<=NF;i++)printf("ark:%s ",$i);}' $temp/train_subset_outputs.1)
  echo "$0: Generating training subset examples on disk"
  $cmd $dir/log/train_subset_create_examples.1.log \
    nnet3-dvector-get-egs --num-pdfs=$num_pdfs $egs_opts \
      $temp/train_subset_ranges.1 "$train_subset_feats" $train_subset_outputs || touch $dir/.error &

  valid_outputs=$(awk '{for(i=1;i<=NF;i++)printf("ark:%s ",$i);}' $temp/valid_outputs.1)
  echo "$0: Generating validation examples on disk"
  $cmd $dir/log/valid_create_examples.1.log \
    nnet3-dvector-get-egs --num-pdfs=$num_pdfs $egs_opts \
      $temp/valid_ranges.1 "$valid_feats" $valid_outputs || touch $dir/.error &
  wait

  if [ -f $dir/.error ]; then
    echo "$0: Problem detected while dumping examples"
    exit 1
  fi
fi

if [ $stage -le 4 ]; then
  echo "$0: Shuffling order of archives on disk"
  $cmd --max-jobs-run $nj JOB=1:$num_train_archives $dir/log/shuffle.JOB.log \
    nnet3-shuffle-egs --srand=JOB ark:$dir/egs_temp.JOB.ark \
    ark,scp:$dir/egs.JOB.ark,$dir/egs.JOB.scp || exit 1;
  $cmd --max-jobs-run $nj JOB=1:$num_diagnostic_archives $dir/log/train_subset_shuffle.JOB.log \
    nnet3-shuffle-egs --srand=JOB ark:$dir/train_subset_egs_temp.JOB.ark \
    ark,scp:$dir/train_diagnostic_egs.JOB.ark,$dir/train_diagnostic_egs.JOB.scp || exit 1;
  $cmd --max-jobs-run $nj JOB=1:$num_diagnostic_archives $dir/log/valid_shuffle.JOB.log \
    nnet3-shuffle-egs --srand=JOB ark:$dir/valid_egs_temp.JOB.ark \
    ark,scp:$dir/valid_egs.JOB.ark,$dir/valid_egs.JOB.scp || exit 1;
fi

if [ $stage -le 5 ]; then
  for file in $(for x in $(seq $num_diagnostic_archives); do echo $dir/train_subset_egs_temp.$x.ark; done) \
    $(for x in $(seq $num_diagnostic_archives); do echo $dir/valid_egs_temp.$x.ark; done) \
    $(for x in $(seq $num_train_archives); do echo $dir/egs_temp.$x.ark; done); do
    [ -L $file ] && rm $(readlink -f $file)
    rm $file
  done
  rm -rf $dir/valid_diagnostic.scp $dir/train_diagnostic.scp
  for x in $(seq $num_diagnostic_archives); do
    cat $dir/train_diagnostic_egs.$x.scp >> $dir/train_diagnostic.scp
    cat $dir/valid_egs.$x.scp >> $dir/valid_diagnostic.scp
  done
  ln -sf train_diagnostic.scp $dir/combine.scp
fi

echo "$0: Finished preparing training examples"
