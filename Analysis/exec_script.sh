#!/usr/bin/env bash
set -euo pipefail
#This script will be called with sbatch by miniwdl
#Originally meant to only exec the arguments, here we make use of $SLURM_TMPDIR
#By copying the working directory to $SLURM_TMPDIR, we can take advantage of the fast local disk
#Then copy back the results to the original working directory

module load apptainer/1.3.5
declare -a bindList
inPwd=0
inBind=0
echo "Original Command:"
for var in "$@"; do
    echo "$var"
done
echo "Starting arg parse"
(for var in "$@"; do
    #Previous argument was --pwd or --bind? If so, extract pwd or add to bind list
    if [[ $inPwd -eq 1 ]]; then 
        pwd="$var"
        inPwd=0
    elif [[ $inBind -eq 1 ]]; then 
        bindList+=("$var")
        inBind=0
        #We need to capture the workdir from the bind list 
        #but avoid anything that is not in the pipeline workdir
        if [[ $var == *".txt"* ]] && [[ $var == *"stdout"* ]]; then 
            #stdout file is garanteed to be in the workdir
            stdo=$(echo "$var" | cut -d: -f1)
            workdir=$(dirname "$stdo")
            echo "Found stdout bind: $var" >>$workdir/execOut.txt
        fi
    fi

    #If true, next argument will be pwd, bind
    if [[ $var == "--pwd" ]]; then inPwd=1; continue 
    elif [[ $var == "--bind" ]]; then inBind=1; continue
    else inPwd=0; inBind=0 
    fi

    #Extract the sif file and put it on SLURM_TMPDIR (could help with transport endpoint shutdown errors)
    if [[ $var == *".sif"* ]]; then 
        sif=$var
        cp -v $sif $SLURM_TMPDIR
        sif_tmpdir=$SLURM_TMPDIR/$(basename $sif)
        if [[ ! -f "$sif_tmpdir" ]]; then
            echo "Error, could not copy image $sif to $sif_tmpdir"
            exit 1
        fi
    fi

done
date >>$workdir/execOut.txt
echo "Found mnt pwd: $pwd" >>$workdir/execOut.txt
echo "Found local workdir: $workdir" >>$workdir/execOut.txt
bindString=$(IFS=, ; echo "${bindList[*]}")
bindString+=",$SLURM_TMPDIR/$workdir:$pwd"
apptainerCmd="apptainer exec -C -W $SLURM_TMPDIR --pwd $pwd --bind $bindString $sif_tmpdir /bin/bash $workdir/command >> .$workdir/stdout.txt 2>> ../stderr.txt"
echo "ApptainerCmd: $apptainerCmd" >>$workdir/execOut.txt

echo "Syncing to $SLURM_TMPDIR/$workdir" >>$workdir/execOut.txt
rsync -aRv $workdir $SLURM_TMPDIR >>$workdir/execOut.txt
date >>$workdir/execOut.txt

echo "Running Apptainer command" >>$workdir/execOut.txt
apptainer exec -C -W $SLURM_TMPDIR --pwd $pwd --bind $bindString $sif_tmpdir /bin/bash ../command >> $workdir/stdout.txt 2>> $workdir/stderr.txt
# echo "Syncing back to $workdir" >>$workdir/execOut.txt
# date >>$workdir/execOut.txt
# cd $SLURM_TMPDIR
# echo "rsync -aRuv ./$workdir /$workdir" >>$workdir/execOut.txt
# #--exclude '*/_singularity_tmpdir_*/' --exclude '*/write_*/'
# rsync -aRuv ./$workdir /$workdir >>$workdir/execOut.txt
date >>$workdir/execOut.txt)
exit
#exec "$@"