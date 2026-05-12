export OMP_NUM_THREADS=1
source /opt/conda/etc/profile.d/conda.sh && conda activate dp-train

lmp_dp -i input.lammps  0>> model_devi.log 2>> model_devi.log 


