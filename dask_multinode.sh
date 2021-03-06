#!/bin/bash
set -e

if [ ${SLURM_NTASKS} -lt 3 ]; then
        echo "Error: You should specify at least three nodes for Dask multi-node computing."
        exit 1
fi

WORKSPACE="/workspace"
SCHEDULER="dask-scheduler-${SLURM_JOB_ID}.json"
LOGS="dask-log-${SLURM_JOB_ID}.txt"
NODESYNC="dask-node-${SLURM_JOB_ID}.txt"
let NUMWORKERS=${SLURM_NTASKS}-2

export DASK_DISTRIBUTED__COMM__TIMEOUTS__CONNECT="30s"
export WORKSPACE
export SCHEDULER

source activate rapids
apt update -qq > /dev/null 2>&1
apt install -qq -y build-essential > /dev/null 2>&1
pip install -q nvtabular==0.6.1 > /dev/null 2>&1
cd ${WORKSPACE}

echo "+++++++++++++++++++++++++++++++++++++++"
echo "Slurm job id: ${SLURM_JOB_ID}"
echo "Slurm number of nodes: ${SLURM_NTASKS}"
echo "Slurm number of workers: ${NUMWORKERS}"
echo "Slurm process id: ${SLURM_PROCID}"
echo "Slurm node name: ${SLURMD_NODENAME}"
echo "Current working directory: ${PWD}"
echo "Scheulder file: ${SCHEDULER}"
echo "+++++++++++++++++++++++++++++++++++++++"
echo "++++++++++++++GPU list+++++++++++++++++"
nvidia-smi -L
echo "+++++++++++++++++++++++++++++++++++++++"
echo "${SLURM_PROCID}" >> ${NODESYNC}

function launch_scheduler() { python -u -c "import dask_scheduler; dask_scheduler.run_as_scheduler('${SCHEDULER}')" ; }
function launch_worker() { python -u -c "import dask_cudaworker; dask_cudaworker.run_as_cuda_worker('${SCHEDULER}')" ; }

export -f launch_scheduler
export -f launch_worker

while [ `wc -l < ${NODESYNC}` -lt ${SLURM_NTASKS} ]
do
        if [ ${SLURM_PROCID} -eq 0 ]; then
                echo "Waiting for all nodes to be launched ...`wc -l < ${NODESYNC}`/${SLURM_NTASKS}"
                if [ ! -d logs ]; then
                        mkdir logs
                fi
        fi
        sleep 2
done

# Dask-Scheduler on rank 1
if [ ${SLURM_PROCID} -eq 1 ]; then
        echo "All ${SLURM_NTASKS} nodes are successfully launched."
        sleep 2
        rm -rf ${NODESYNC}
        bash -c "launch_scheduler" > logs/${LOGS} 2>&1
        echo "<< Dask-Scheduler is launched at rank ${SLURM_PROCID} >>" 
fi
sleep 2

# Dask-Worker on rank > 1
if [ ${SLURM_PROCID} -gt 1 ]; then
        bash -c "launch_worker" > logs/${LOGS} 2>&1
        echo "<< Dask-Worker is launched at rank ${SLURM_PROCID} >>" 
fi
sleep 2

# Dask-Client on rank 0
if [ ${SLURM_PROCID} -eq 0 ]; then
        python -u dask_main.py --slurm True --base-dir ${WORKSPACE} --clustering-algorithm KMeans
fi